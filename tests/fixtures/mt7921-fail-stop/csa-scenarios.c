/* Given a live CSA transaction, distinguish driver notification, core drop,
 * and final object destruction. Each named scenario runs in a fresh process.
 */
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include "csa-actual.c"

static struct fixture fixture;
static int ran, passed, undecidable;
static struct mt792x_vif *mvif(void) { return (void *)fixture.sdata.vif.drv_priv; }
static struct ieee80211_channel_switch switch_request(void)
{
    return (struct ieee80211_channel_switch){ .chandef=fixture.context.def, .count=3 };
}
static void failed(void) { set_bit(MT76_STATE_RECOVERY_FAILED, &fixture.dev.mphy.state); }
static bool clean(void) { return !atomic_load(&fixture.faults); }
static bool pending_drop(void) { return atomic_load(&fixture.sdata.u.mgd.csa_connection_drop_work.queued); }

void ieee80211_link_release_channel(struct ieee80211_link_data *link)
{
    struct mt792x_vif *vif = (void *)link->sdata->vif.drv_priv;
    if (vif->bss_conf.mt76.ctx)
        mt792x_unassign_vif_chanctx(&fixture.local.hw, &link->sdata->vif,
                                  link->conf, vif->bss_conf.mt76.ctx);
}

static void consume_drop(void)
{
    mutex_lock(&fixture.wiphy.mtx);
    if (atomic_exchange(&fixture.sdata.u.mgd.csa_connection_drop_work.queued, false))
        ieee80211_csa_connection_drop_work(&fixture.wiphy, &fixture.sdata.u.mgd.csa_connection_drop_work);
    mutex_unlock(&fixture.wiphy.mtx);
}

static bool completed_failure(void)
{
    bool notified = pending_drop() && fixture.sdata.vif.cfg.assoc &&
                    fixture.sdata.vif.bss_conf.csa_active && fixture.sdata.deflink.u.mgd.csa.blocked_tx;
    consume_drop();
    return notified && !fixture.sdata.vif.cfg.assoc && !fixture.sdata.vif.bss_conf.csa_active &&
           !fixture.sdata.deflink.u.mgd.csa.blocked_tx && fixture.disconnects == 1 && clean();
}

static void *timer_callback(void *unused)
{
    (void)unused;
    assert(mvif()->csa_timer.queued && fixture.clock >= mvif()->csa_timer.expires);
    atomic_store(&mvif()->csa_timer.queued, false);
    fixture_begin_running(&mvif()->csa_timer.running, &mvif()->csa_timer.owner); fixture_gate(G_TIMER_RUNNING);
    if (fixture.destroyed || !mvif()->csa_timer.initialized) {
        fprintf(stderr,"LIFETIME: running timer crossed drv_priv memset\n"); fflush(stderr); _exit(3);
    }
    mt792x_csa_timer(&mvif()->csa_timer);
    fixture_end_running(&mvif()->csa_timer.running);
    return NULL;
}
static void *work_callback(void *unused)
{
    (void)unused; atomic_store(&mvif()->csa_work.queued, false);
    fixture_begin_running(&mvif()->csa_work.running, &mvif()->csa_work.owner); fixture_gate(G_WORK_RUNNING);
    if (fixture.destroyed || !mvif()->csa_work.initialized) {
        fprintf(stderr,"LIFETIME: running work crossed drv_priv memset\n"); fflush(stderr); _exit(3);
    }
    mt7921_csa_work(&mvif()->csa_work);
    fixture_end_running(&mvif()->csa_work.running);
    return NULL;
}
static pthread_t start(void *(*callback)(void *))
{
    pthread_t thread; assert(!pthread_create(&thread, NULL, callback, NULL)); return thread;
}
static void join(pthread_t thread) { assert(!pthread_join(thread, NULL)); }
static pthread_t expire_timer(void)
{
    assert(mvif()->csa_timer.queued && mvif()->csa_timer.expires > fixture.clock);
    /* Advance modeled time to the original producer's deadline, not to reset. */
    fixture.clock = mvif()->csa_timer.expires;
    return start(timer_callback);
}

/* Modeled do_stop stages are checked against the original complete definition.
 * The real drv_remove_interface and actual ops binding run before real memset.
 */
static void destroy_interface(void)
{
    lockdep_assert_wiphy(&fixture.wiphy);
    drv_remove_interface(&fixture.local, &fixture.sdata);
    memset(fixture.sdata.vif.drv_priv, 0, sizeof(fixture.sdata.vif.drv_priv));
    fixture_mark_destroyed();
}
static void *remove_callback(void *unused)
{
    (void)unused; mutex_lock(&fixture.wiphy.mtx); destroy_interface(); mutex_unlock(&fixture.wiphy.mtx);
    return NULL;
}

int drv_pre_channel_switch(struct ieee80211_sub_if_data *sdata, struct ieee80211_channel_switch *request)
{
    lockdep_assert_wiphy(sdata->local->hw.wiphy);
    atomic_fetch_add(&fixture.pre_calls, 1);
    return mt7921_pre_channel_switch(&sdata->local->hw, &sdata->vif, request);
}
void drv_channel_switch(struct ieee80211_local *local, struct ieee80211_sub_if_data *sdata,
                        struct ieee80211_channel_switch *request)
{
    lockdep_assert_wiphy(local->hw.wiphy); fixture_gate(G_CORE_PRODUCE);
    local->ops->channel_switch(&local->hw, &sdata->vif, request);
}
void drv_channel_switch_rx_beacon(struct ieee80211_sub_if_data *sdata, struct ieee80211_channel_switch *request)
{
    lockdep_assert_wiphy(sdata->local->hw.wiphy);
    mt7921_channel_switch_rx_beacon(&sdata->local->hw, &sdata->vif, request);
}
static void *core_start_csa(void *unused)
{
    (void)unused; struct ieee802_11_elems elements = {0};
    mutex_lock(&fixture.wiphy.mtx);
    ieee80211_sta_process_chanswitch(&fixture.sdata.deflink, 0, 0, &elements, &elements, IEEE80211_CSA_SOURCE_BEACON);
    mutex_unlock(&fixture.wiphy.mtx); return NULL;
}
static bool terminal_core_pre(void)
{
    fixture.sdata.vif.bss_conf.csa_active = false;
    fixture.sdata.deflink.u.mgd.csa.blocked_tx = false;
    failed(); join(start(core_start_csa));
    return fixture.pre_calls == 1 && !mvif()->csa_timer.queued && completed_failure();
}

static bool terminal_pre(void)
{
    failed(); struct ieee80211_channel_switch request = switch_request();
    return mt7921_pre_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request) == -EIO;
}
static bool terminal_producer(void)
{
    failed(); struct ieee80211_channel_switch request = switch_request();
    mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
    return !mvif()->csa_timer.queued && completed_failure();
}
static bool terminal_rx(void)
{
    failed(); struct ieee80211_channel_switch request = switch_request();
    mt7921_channel_switch_rx_beacon(&fixture.local.hw, &fixture.sdata.vif, &request);
    return !mvif()->csa_timer.queued && completed_failure();
}
static bool terminal_timer(void)
{
    failed(); mt792x_csa_timer(&mvif()->csa_timer);
    return !mvif()->csa_work.queued && completed_failure();
}
static bool terminal_work(void)
{
    failed(); mt7921_csa_work(&mvif()->csa_work);
    return !fixture.mcu && !fixture.pm_wakes && !fixture.pm_releases && completed_failure();
}

#ifdef CSA_MODE_WIP
static void *unsafe_reset(void *unused)
{
    (void)unused; mt7921e_stop_deferred_work(&fixture.dev); return NULL;
}
static bool check_then_memset(void)
{
    failed(); fixture_arm_gate(G_TIMER_CANCEL);
    pthread_t reset = start(unsafe_reset); fixture_wait_gate();
    /* iflist and phy checks have passed. Framework removal does not need iflist. */
    mutex_lock(&fixture.wiphy.mtx); destroy_interface(); mutex_unlock(&fixture.wiphy.mtx);
    fixture_release_gate(); join(reset);
    printf("TRACE actual WIP: destroyed=%d timer/work lifetime faults=%d\n", fixture.destroyed, fixture.faults);
    return clean();
}
#endif

#ifdef CSA_MODE_PATCHED
#include "csa-patched-scenarios.h"
#endif

/* Per-child diagnostics bind explicit exit 3 to its own contract/lifetime fault.
 * Neither unrelated diagnostics nor any signal can turn a crash into evidence.
 */
static void run(const char *name, bool (*scenario)(void))
{
    FILE *diagnostics=tmpfile(); assert(diagnostics);
    fflush(NULL); pid_t child = fork(); assert(child >= 0);
    if (!child) {
        assert(dup2(fileno(diagnostics),STDERR_FILENO)>=0);
        alarm(15); /* Safety valve: timeout is undecidable, never a kill. */
        fixture_init(&fixture); fixture.ops.remove_interface = ACTUAL_REMOVE;
        fixture.ops.channel_switch = mt7921_channel_switch;
        bool result = scenario(); fflush(NULL); _exit(result ? 0 : 1);
    }
    int status; assert(waitpid(child, &status, 0) == child);
    rewind(diagnostics);
    char line[1024]; bool contract=false;
    while (fgets(line,sizeof(line),diagnostics)) {
        fputs(line,stderr);
        contract |= !strncmp(line,"CONTRACT: ",10) || !strncmp(line,"LIFETIME: ",10);
    }
    assert(!ferror(diagnostics)); fclose(diagnostics);
    bool exited=WIFEXITED(status);
    int code=exited ? WEXITSTATUS(status) : -1;
    bool ok=exited && code==0;
    bool known=exited && (code==0 || code==1 || (code==3 && contract));
    ran++; passed+=ok; undecidable+=!known;
    printf("%s %s\n",ok ? "PASS" : "FAIL",name);
    printf("CSA_OUTCOME %s kind=%s exit=%d signal=%d\n",name,
        !known ? "undecidable" : ok ? "pass" : code==1 ? "behavior" : "contract",
        code,WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    if (WIFSIGNALED(status)) printf("TRACE child signal=%d (not behavior red)\n",WTERMSIG(status));
}

#ifdef CSA_MODE_PATCHED
static void run_patched_cases(void)
{
    run("C06 REMOVED pre rejects transaction", removed_pre);
    run("C07 healthy pre accepts valid station", healthy_pre);
    run("C08 healthy pre preserves invalid type", wrong_type_pre);
    run("C09 healthy pre preserves missing association", unassociated_pre);
    run("C10 healthy pre preserves unusable chandef", unusable_pre);
    run("C11 healthy work retains PM and success core queue", healthy_success);
    run("C12 no association emits no completion", no_assoc_completion);
    run("C13 inactive transaction emits no completion", inactive_completion);
    run("C14 nonstation emits no completion", nonstation_completion);
    run("C15 finite duplicate notifications merge core drop", duplicate_completion);
    run("C16 beacon count zero leaves timer alone", rx_no_count);
    run("C17 beacon other chandef leaves timer alone", rx_other_channel);
    run("C18 checked producer then FAILED permits one timer tail", add_tail);
    run("C19 checked beacon then FAILED permits one timer tail", mod_tail);
    run("C20 checked timer then FAILED permits one consumed work", timer_queue_tail);
    run("C21 running work before mutex rechecks FAILED", mutex_wait_terminal);
    run("C22 old MCU leaf crossing FAILED finishes with failure", mcu_inflight_terminal);
    run("C23 FAILED reset holds no vif owner or wiphy wait", reset_no_vif);
    run("C24 inactive/no-context remove joins then clears private", remove_order);
    run("C25 running timer finishes before remove memset", remove_running_timer);
    run("C26 running work finishes before remove memset", remove_running_work);
    run("C27 abort then remove repeats safe joins", abort_cleanup);
    run("C28 unassign clears context outside joins then remove", unassign_cleanup);
    run("C29 old RCU notification precedes grace and core cancellation", rcu_completion_before_leave);
    run("C30 completion after station leave cannot requeue core drop", completion_after_leave);
    run("C31 mt7925 timer preserves shared original queue behavior", mt7925_timer);
    run("C32 healthy USB-shaped CSA retains common remove", usb_csa);
    run("C33 healthy SDIO-shaped CSA retains common remove", sdio_csa);
    run("C34 real core pre error takes drop_connection", terminal_core_pre);
    run("C35 healthy MCU error reports software failure", healthy_error);
    run("C36 real core sets flags before terminal void producer", core_producer_terminal);
    run("C37 healthy real core delegates one driver timer", healthy_core_producer);
    run("C38 running timer finishes before abort/remove", abort_running_timer);
    run("C39 running work finishes before abort/remove", abort_running_work);
    run("C40 running work finishes before unassign/remove", unassign_running_work);
    run("C41 healthy queued remove preserves original cleanup", healthy_remove);
    run("C42 nonstation remove still joins initialized objects", nonstation_remove);
    run("C43 core add failure never removes uninitialized private", failed_add_no_remove);
    run("C44 REMOVED timer completes without driver queue", removed_timer);
    run("C45 REMOVED work bypasses PM/MCU and completes", removed_work);
    run("C46 REMOVED void producer completes without arming", removed_producer);
    run("C47 REMOVED beacon completes without modifying timer", removed_rx);
    run("C48 inactive unassign leaves final joins to remove", inactive_unassign);
}
#endif

int main(void)
{
#ifdef CSA_MODE_WIP
    run("C00 WIP iflist/phy check then framework memset", check_then_memset);
    const int expected = 1;
#else
    run("C01 terminal pre rejects transaction", terminal_pre);
    run("C02 terminal producer completes without arming", terminal_producer);
    run("C03 terminal beacon completes without mod_timer", terminal_rx);
    run("C04 terminal timer reports failure without driver work", terminal_timer);
    run("C05 terminal work avoids PM/MCU and completes", terminal_work);
#ifdef CSA_MODE_PATCHED
    run_patched_cases();
    const int expected = 48;
#else
    run("C34 real core pre error takes drop_connection", terminal_core_pre);
    const int expected = 6;
#endif
#endif
    printf("partition=CSA ran=%d passed=%d failed=%d expected=%d\n", ran, passed, ran-passed, expected);
    printf("CSA_CLASSIFICATION ran=%d expected=%d undecidable=%d\n",ran,expected,undecidable);
    if (ran != expected || undecidable) return 2;
    return passed == expected ? 0 : 1;
}
