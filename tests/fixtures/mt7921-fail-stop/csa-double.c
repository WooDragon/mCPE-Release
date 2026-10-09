/* Pthread-backed CSA API leaves. Sync cancellation waits for running owners;
 * RCU grace waits for readers that existed at entry, not future readers.
 */
#include <unistd.h>
#include "csa-state.h"
#include "csa-double.h"

struct fixture *current;
_Thread_local unsigned rcu_depth;
static _Thread_local int thread_id;
static atomic_int next_thread;
static pthread_mutex_t events = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static enum gate_point armed;
static bool reached, released;
static int controller;
static unsigned rcu_generation, readers[2];
static _Thread_local unsigned reader_generation;
static struct mutex *waiting[32];
static int joining[32];

static int identity(void)
{
    if (!thread_id) thread_id = atomic_fetch_add(&next_thread, 1) + 1;
    assert(thread_id < 32);
    return thread_id;
}

/* events protects all wait edges; cycles are rejected, never force-unlocked. */
static void check_wait_cycle(int id, int owner)
{
    for (int depth = 0; owner && depth < 32; depth++) {
        if (owner == id) { fprintf(stderr, "CONTRACT: lock/join wait cycle\n"); fflush(stderr); _exit(3); }
        struct mutex *next = waiting[owner];
        owner = next ? atomic_load(&next->owner) : joining[owner];
    }
}

static void announce(void)
{
    pthread_mutex_lock(&events);
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events);
}

void fixture_wait_counter(atomic_int *counter, int value)
{
    pthread_mutex_lock(&events);
    while (atomic_load(counter) < value &&
           !(counter == &current->sync_waits && atomic_load(&current->destroyed)))
        pthread_cond_wait(&changed, &events);
    pthread_mutex_unlock(&events);
}

void fixture_arm_gate(enum gate_point point)
{
    pthread_mutex_lock(&events);
    assert(armed == G_NONE);
    armed = point; reached = released = false; controller = identity();
    pthread_mutex_unlock(&events);
}

void fixture_gate(enum gate_point point)
{
    pthread_mutex_lock(&events);
    if (armed == point && !reached) {
        reached = true; pthread_cond_broadcast(&changed);
        int id = identity(); joining[id] = controller;
        check_wait_cycle(id, controller);
        while (!released) pthread_cond_wait(&changed, &events);
        joining[id] = 0; armed = G_NONE;
    }
    pthread_mutex_unlock(&events);
}

void fixture_wait_gate(void)
{
    pthread_mutex_lock(&events);
    while (!reached && !atomic_load(&current->callbacks_finished))
        pthread_cond_wait(&changed, &events);
    pthread_mutex_unlock(&events);
}

void fixture_release_gate(void)
{
    pthread_mutex_lock(&events);
    released = true; pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events);
}

void fixture_might_sleep(void)
{
    if (rcu_depth) { fprintf(stderr, "CONTRACT: sleep inside RCU\n"); fflush(stderr); _exit(3); }
}

bool fixture_owned(struct mutex *lock)
{
    return atomic_load(&lock->owner) == identity();
}

void mutex_lock(struct mutex *lock)
{
    fixture_might_sleep();
    if (lock == &current->dev.mt76.mutex) fixture_gate(G_MUTEX_WAIT);
    int id = identity();
    pthread_mutex_lock(&events);
    waiting[id] = lock;
    check_wait_cycle(id, atomic_load(&lock->owner));
    pthread_mutex_unlock(&events);
    assert(pthread_mutex_lock(&lock->lock) == 0);
    pthread_mutex_lock(&events);
    waiting[id] = NULL; atomic_store(&lock->owner, id);
    pthread_mutex_unlock(&events);
}

void mutex_unlock(struct mutex *lock)
{
    assert(fixture_owned(lock));
    atomic_store(&lock->owner, 0);
    assert(pthread_mutex_unlock(&lock->lock) == 0);
}

void rcu_read_lock(void)
{
    pthread_mutex_lock(&events);
    if (rcu_depth++ == 0) {
        reader_generation = rcu_generation; readers[reader_generation]++;
        atomic_fetch_add(&current->rcu_readers, 1);
    }
    pthread_mutex_unlock(&events);
}

void rcu_read_unlock(void)
{
    pthread_mutex_lock(&events);
    assert(rcu_depth);
    if (--rcu_depth == 0) {
        readers[reader_generation]--; atomic_fetch_sub(&current->rcu_readers, 1);
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events);
}

void synchronize_rcu(void)
{
    fixture_might_sleep();
    pthread_mutex_lock(&events);
    unsigned old = rcu_generation;
    rcu_generation ^= 1;
    atomic_fetch_add(&current->grace_waits, 1);
    pthread_cond_broadcast(&changed);
    while (readers[old]) pthread_cond_wait(&changed, &events);
    pthread_mutex_unlock(&events);
}

void synchronize_net(void) { synchronize_rcu(); }

bool fixture_read_once(const atomic_bool *value)
{
    bool result = atomic_load(value);
    if (value == &current->sdata.vif.bss_conf.csa_active) fixture_gate(G_READ_ACTIVE);
    return result;
}

bool test_bit(unsigned bit, const atomic_ulong *state)
{
    bool result = (atomic_load(state) & (1UL << bit)) != 0;
    if (bit == MT76_STATE_RECOVERY_FAILED) fixture_gate(G_DEAD_CHECK);
    return result;
}
void set_bit(unsigned bit, atomic_ulong *state) { atomic_fetch_or(state, 1UL << bit); }
bool test_and_clear_bit(unsigned bit, atomic_ulong *state) { return (atomic_fetch_and(state, ~(1UL << bit)) & (1UL << bit)) != 0; }

static bool valid_timer(struct timer_list *timer)
{
    if (atomic_load(&timer->initialized)) return true;
    atomic_fetch_add(&current->faults, 1);
    fprintf(stderr, "LIFETIME: timer access after real drv_priv memset\n");
    return false;
}

static bool valid_work(struct work_struct *work)
{
    if (atomic_load(&work->initialized)) return true;
    atomic_fetch_add(&current->faults, 1);
    fprintf(stderr, "LIFETIME: work access after real drv_priv memset\n");
    return false;
}

void add_timer(struct timer_list *timer)
{
    fixture_gate(G_ADD);
    if (valid_timer(timer)) atomic_store(&timer->queued, true);
}

void mod_timer(struct timer_list *timer, unsigned long expires)
{
    fixture_gate(G_MOD);
    if (valid_timer(timer)) { timer->expires = expires; atomic_store(&timer->queued, true); }
}

static void join_running(atomic_bool *running, atomic_int *owner)
{
    fixture_might_sleep();
    /* All CSA sync joins are outside the lock required by csa_work. */
    if (fixture_owned(&current->dev.mt76.mutex)) {
        fprintf(stderr, "CONTRACT: CSA join under mt76 mutex\n"); fflush(stderr); _exit(3);
    }
    pthread_mutex_lock(&events);
    if (atomic_load(running)) {
        atomic_fetch_add(&current->sync_waits, 1);
        pthread_cond_broadcast(&changed);
    }
    int id = identity();
    joining[id] = atomic_load(running) ? atomic_load(owner) : 0;
    check_wait_cycle(id, joining[id]);
    while (atomic_load(running)) pthread_cond_wait(&changed, &events);
    joining[id] = 0;
    pthread_mutex_unlock(&events);
}

void del_timer_sync(struct timer_list *timer)
{
    struct mt792x_vif *vif = (void *)current->sdata.vif.drv_priv;
    if (timer == &vif->csa_timer) fixture_gate(G_TIMER_CANCEL);
    if (!valid_timer(timer)) return;
    atomic_store(&timer->queued, false);
    join_running(&timer->running, &timer->owner);
    struct mt792x_vif *mvif = (void *)current->sdata.vif.drv_priv;
    if (timer == &mvif->csa_timer) {
        atomic_fetch_add(&current->timer_joins, 1);
        atomic_store(&current->timer_order, atomic_fetch_add(&current->sequence, 1) + 1);
    }
}

void cancel_work_sync(struct work_struct *work)
{
    if (!valid_work(work)) return;
    atomic_store(&work->queued, false);
    join_running(&work->running, &work->owner);
    struct mt792x_vif *mvif = (void *)current->sdata.vif.drv_priv;
    if (work == &mvif->csa_work) {
        atomic_fetch_add(&current->work_joins, 1);
        atomic_store(&current->work_order, atomic_fetch_add(&current->sequence, 1) + 1);
    }
}

void cancel_work(struct work_struct *work) { if (valid_work(work)) atomic_store(&work->queued, false); }
void cancel_delayed_work(struct delayed_work *work) { cancel_work(&work->work); }
void cancel_delayed_work_sync(struct delayed_work *work) { cancel_work_sync(&work->work); }

void ieee80211_queue_work(struct ieee80211_hw *hw, struct work_struct *work)
{
    (void)hw; fixture_gate(G_QUEUE);
    if (valid_work(work)) atomic_store(&work->queued, true);
}

void fixture_notification(void) { atomic_fetch_add(&current->notifications, 1); }
void fixture_report_disconnect(void) { atomic_fetch_add(&current->disconnects, 1); }

void wiphy_work_queue(struct wiphy *wiphy, struct wiphy_work *work)
{
    (void)wiphy; fixture_gate(G_CORE_QUEUE);
    atomic_store(&work->queued, true);
    atomic_fetch_add(&current->core_queues, 1);
}
void wiphy_work_cancel(struct wiphy *wiphy, struct wiphy_work *work)
{
    lockdep_assert_wiphy(wiphy); atomic_store(&work->queued, false);
}
void wiphy_hrtimer_work_queue(struct wiphy *wiphy, struct wiphy_hrtimer_work *work, unsigned long delay)
{
    (void)delay; wiphy_work_queue(wiphy, &work->work);
}
void wiphy_hrtimer_work_cancel(struct wiphy *wiphy, struct wiphy_hrtimer_work *work) { wiphy_work_cancel(wiphy, &work->work); }
void wiphy_delayed_work_cancel(struct wiphy *wiphy, struct wiphy_delayed_work *work) { wiphy_work_cancel(wiphy, &work->work); }

int mt76_connac_pm_wake(struct mt76_phy *phy, struct mt76_connac_pm *pm)
{
    (void)phy; (void)pm; fixture_might_sleep();
    assert(fixture_owned(&current->dev.mt76.mutex));
    atomic_fetch_add(&current->pm_wakes, 1);
    return 0;
}
void mt76_connac_power_save_sched(struct mt76_phy *phy, struct mt76_connac_pm *pm)
{
    (void)phy; (void)pm; atomic_fetch_add(&current->pm_releases, 1);
}

int mt76_connac_mcu_uni_set_chctx(struct mt76_phy *phy, void *conf, struct ieee80211_chanctx_conf *context)
{
    (void)conf; (void)context; fixture_might_sleep();
    assert(fixture_owned(&current->dev.mt76.mutex));
    fixture_gate(G_MCU);
    /* Transport leaf refuses FAILED, matching the Task14 transport contract.
     * The CSA consumer must avoid calling even this leaf after observing FAILED.
     */
    atomic_fetch_add(&current->mcu, 1);
    return test_bit(MT76_STATE_RECOVERY_FAILED, &phy->state) ? -EIO : current->mcu_result;
}

void mt792x_mac_link_bss_remove(struct mt792x_dev *dev, struct mt792x_bss_conf *conf, int *sta)
{
    (void)conf; (void)sta; assert(fixture_owned(&dev->mt76.mutex));
    atomic_fetch_add(&current->removals, 1);
    atomic_store(&current->remove_order, atomic_fetch_add(&current->sequence, 1) + 1);
}

void ieee80211_vif_unblock_queues_csa(struct ieee80211_sub_if_data *sdata)
{
    lockdep_assert_wiphy(sdata->local->hw.wiphy);
    sdata->deflink.u.mgd.csa.blocked_tx = false;
}

bool cfg80211_chandef_usable(struct wiphy *wiphy, struct cfg80211_chan_def *def, unsigned flags)
{
    (void)wiphy; (void)flags; return def->usable;
}
bool cfg80211_chandef_identical(struct cfg80211_chan_def *first, struct cfg80211_chan_def *second)
{
    return first->identity == second->identity;
}

static void init_mutex(struct mutex *lock, const char *name)
{
    assert(pthread_mutex_init(&lock->lock, NULL) == 0); lock->name = name;
}
static void init_timer(struct timer_list *timer) { atomic_store(&timer->initialized, true); }
static void init_work(struct work_struct *work) { atomic_store(&work->initialized, true); }

void fixture_init(struct fixture *fixture)
{
    memset(fixture, 0, sizeof(*fixture)); current = fixture;
    init_mutex(&fixture->dev.mt76.mutex, "mt76");
    init_mutex(&fixture->wiphy.mtx, "wiphy");
    init_mutex(&fixture->local.iflist_mtx, "iflist");
    init_mutex(&fixture->sdata.u.mgd.teardown_lock, "teardown");
    fixture->local.hw.wiphy = &fixture->wiphy;
    fixture->local.hw.priv = &fixture->dev;
    fixture->local.interfaces = &fixture->sdata; fixture->local.ops = &fixture->ops;
    fixture->dev.mphy.hw = &fixture->local.hw;
    fixture->dev.mt76.chip = 0x7922; fixture->dev.phy.dev = &fixture->dev;
    fixture->dev.phy.mt76 = &fixture->dev.mphy; fixture->dev.new_ctx = &fixture->context;
    fixture->channel.band = NL80211_BAND_5GHZ;
    fixture->bss.channel = &fixture->channel;
    fixture->context.def = (struct cfg80211_chan_def){ .identity=36, .usable=true, .chan=&fixture->channel };
    struct ieee80211_sub_if_data *sdata = &fixture->sdata;
    sdata->local = &fixture->local; sdata->flags = IEEE80211_SDATA_IN_DRIVER;
    sdata->vif.type = NL80211_IFTYPE_STATION; sdata->vif.cfg.assoc = true;
    sdata->vif.bss_conf.csa_active = true; sdata->vif.bss_conf.beacon_int = 100;
    sdata->vif.bss_conf.bss = &fixture->bss;
    sdata->vif.bss_conf.chanreq.oper = fixture->context.def;
    sdata->vif.bss_conf.chanreq.oper.identity = 35;
    sdata->vif.bss_conf.chanctx_conf = &fixture->core_context.conf;
    sdata->u.mgd.associated = true; sdata->deflink.sdata = sdata;
    sdata->deflink.conf = &sdata->vif.bss_conf; sdata->link[0] = &sdata->deflink;
    sdata->deflink.u.mgd.csa.blocked_tx = true;
    struct mt792x_vif *mvif = (void *)sdata->vif.drv_priv;
    mvif->phy = &fixture->dev.phy; mvif->bss_conf.mt76.ctx = &fixture->context;
    init_work(&mvif->csa_work); init_timer(&mvif->csa_timer);
    init_timer(&fixture->dev.phy.roc_timer); init_work(&fixture->dev.phy.roc_work);
    init_work(&fixture->dev.mphy.mac_work.work); init_work(&fixture->dev.phy.scan_work.work);
    init_work(&fixture->dev.pm.wake_work); init_work(&fixture->dev.pm.ps_work.work);
    init_work(&fixture->dev.coredump.work.work); init_work(&fixture->dev.ipv6_ns_work);
    init_timer(&fixture->local.dynamic_ps_timer);
    init_timer(&sdata->u.mgd.timer); init_timer(&sdata->u.mgd.conn_mon_timer); init_timer(&sdata->u.mgd.bcn_mon_timer);
    armed = G_NONE; reached = released = false; identity();
}

/* Packet parsing is a leaf: these tests start from one valid station CSA IE.
 * The complete core process_chanswitch body still chooses pre/producer/drop.
 */
int ieee80211_parse_ch_switch_ie(struct ieee80211_sub_if_data *sdata, struct ieee802_11_elems *elements,
    enum nl80211_band band, int capabilities, void *connection, u8 *address, bool unprotected,
    struct ieee80211_csa_ie *result)
{
    (void)capabilities; (void)connection; (void)address;
    assert(sdata == &current->sdata && elements && band == NL80211_BAND_5GHZ && !unprotected);
    *result = (struct ieee80211_csa_ie){ .chanreq={ .oper=current->context.def }, .mode=true, .count=3 };
    return 0;
}
void ieee80211_vif_block_queues_csa(struct ieee80211_sub_if_data *sdata)
{
    lockdep_assert_wiphy(sdata->local->hw.wiphy);
    sdata->deflink.u.mgd.csa.blocked_tx = true;
}

/* Tests call this only after the actual original consumer/wrapper returns. */
void fixture_mark_destroyed(void)
{
    atomic_store(&current->destroyed, true); announce();
}

void fixture_begin_running(atomic_bool *running, atomic_int *owner)
{
    atomic_store(owner, identity()); atomic_store(running, true);
}

void fixture_end_running(atomic_bool *running)
{
    atomic_store(running, false); atomic_fetch_add(&current->callbacks_finished, 1); announce();
}
