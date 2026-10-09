/* CSA patched behavior/lifecycle cases, included in the same source TU. */
static void *software_complete(void *unused)
{
    (void)unused; mt792x_csa_complete(mvif(), false); return NULL;
}
static bool removed_pre(void)
{
    set_bit(MT76_REMOVED, &fixture.dev.mphy.state);
    struct ieee80211_channel_switch request = switch_request();
    return mt7921_pre_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request) == -EIO;
}
static bool healthy_pre(void)
{
    struct ieee80211_channel_switch request = switch_request();
    return !mt7921_pre_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
}
static bool wrong_type_pre(void)
{
    fixture.sdata.vif.type = NL80211_IFTYPE_AP; struct ieee80211_channel_switch request = switch_request();
    return mt7921_pre_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request) == -EOPNOTSUPP;
}
static bool unassociated_pre(void)
{
    fixture.sdata.vif.cfg.assoc = false; struct ieee80211_channel_switch request = switch_request();
    return mt7921_pre_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request) == -EOPNOTSUPP;
}
static bool unusable_pre(void)
{
    struct ieee80211_channel_switch request = switch_request(); request.chandef.usable = false;
    return mt7921_pre_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request) == -EOPNOTSUPP;
}
static bool healthy_success(void)
{
    mt7921_csa_work(&mvif()->csa_work);
    return fixture.mcu == 1 && fixture.pm_wakes == 1 && fixture.pm_releases == 1 &&
           !pending_drop() && fixture.sdata.deflink.u.mgd.csa.switch_work.work.queued &&
           fixture.sdata.vif.cfg.assoc && clean();
}
static bool no_assoc_completion(void)
{
    failed(); fixture.sdata.vif.cfg.assoc = false;
    mt792x_csa_complete(mvif(), false); return !fixture.notifications && !pending_drop();
}
static bool inactive_completion(void)
{
    failed(); fixture.sdata.vif.bss_conf.csa_active = false;
    mt792x_csa_complete(mvif(), false); return !fixture.notifications && !pending_drop();
}
static bool nonstation_completion(void)
{
    failed(); fixture.sdata.vif.type = NL80211_IFTYPE_AP;
    mt792x_csa_complete(mvif(), false); return !fixture.notifications && !pending_drop();
}
static bool duplicate_completion(void)
{
    failed(); mt792x_csa_complete(mvif(), false); mt792x_csa_complete(mvif(), false);
    bool once = completed_failure();
    /* The real core disconnect has its own associated early return. */
    mutex_lock(&fixture.wiphy.mtx);
    ieee80211_csa_connection_drop_work(&fixture.wiphy, &fixture.sdata.u.mgd.csa_connection_drop_work);
    mutex_unlock(&fixture.wiphy.mtx);
    return once && fixture.notifications == 2 && fixture.disconnects == 1;
}
static bool rx_no_count(void)
{
    struct ieee80211_channel_switch request = switch_request(); request.count = 0;
    mt7921_channel_switch_rx_beacon(&fixture.local.hw, &fixture.sdata.vif, &request);
    return !mvif()->csa_timer.queued;
}
static bool rx_other_channel(void)
{
    struct ieee80211_channel_switch request = switch_request(); request.chandef.identity++;
    mt7921_channel_switch_rx_beacon(&fixture.local.hw, &fixture.sdata.vif, &request);
    return !mvif()->csa_timer.queued;
}
static void *produce(void *unused)
{
    (void)unused; struct ieee80211_channel_switch request = switch_request();
    mutex_lock(&fixture.wiphy.mtx);
    mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
    mutex_unlock(&fixture.wiphy.mtx); return NULL;
}
static void *produce_rx(void *unused)
{
    (void)unused; struct ieee80211_channel_switch request = switch_request();
    mutex_lock(&fixture.wiphy.mtx);
    mt7921_channel_switch_rx_beacon(&fixture.local.hw, &fixture.sdata.vif, &request);
    mutex_unlock(&fixture.wiphy.mtx); return NULL;
}
static bool producer_tail(bool rx)
{
    fixture_arm_gate(rx ? G_MOD : G_ADD); pthread_t producer = start(rx ? produce_rx : produce);
    fixture_wait_gate(); failed(); mt7921e_stop_deferred_work(&fixture.dev);
    bool no_reset_join = !fixture.timer_joins && !fixture.work_joins;
    fixture_release_gate(); join(producer);
    bool armed_once = mvif()->csa_timer.queued && mvif()->csa_timer.expires > 1;
    join(expire_timer());
    return no_reset_join && armed_once && !mvif()->csa_timer.queued && !mvif()->csa_work.queued && completed_failure();
}
static bool add_tail(void) { return producer_tail(false); }
static bool mod_tail(void) { return producer_tail(true); }
static bool timer_queue_tail(void)
{
    struct ieee80211_channel_switch request = switch_request();
    mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
    fixture_arm_gate(G_QUEUE); pthread_t timer = expire_timer(); fixture_wait_gate();
    failed(); mt7921e_stop_deferred_work(&fixture.dev); fixture_release_gate(); join(timer);
    bool one_work = mvif()->csa_work.queued;
    join(start(work_callback));
    return one_work && !fixture.mcu && !fixture.pm_releases && completed_failure();
}
static bool mutex_wait_terminal(void)
{
    fixture_arm_gate(G_MUTEX_WAIT); pthread_t work = start(work_callback); fixture_wait_gate();
    failed(); fixture_release_gate(); join(work);
    return !fixture.mcu && !fixture.pm_wakes && !fixture.pm_releases && completed_failure();
}
static bool mcu_inflight_terminal(void)
{
    fixture_arm_gate(G_MCU); pthread_t work = start(work_callback); fixture_wait_gate();
    failed(); fixture_release_gate(); join(work);
    return fixture.mcu == 1 && completed_failure();
}
static bool reset_no_vif(void)
{
    failed(); memset(fixture.sdata.vif.drv_priv, 0, sizeof(fixture.sdata.vif.drv_priv));
    fixture_mark_destroyed(); mutex_lock(&fixture.wiphy.mtx);
    mt7921e_stop_deferred_work(&fixture.dev); mutex_unlock(&fixture.wiphy.mtx);
    return clean() && !fixture.timer_joins && !fixture.work_joins;
}
static bool remove_order(void)
{
    failed(); fixture.sdata.vif.bss_conf.csa_active = false; mvif()->bss_conf.mt76.ctx = NULL;
    mvif()->csa_timer.queued = true; mvif()->csa_work.queued = true;
    join(start(remove_callback));
    return fixture.destroyed && clean() && fixture.timer_order < fixture.work_order &&
           fixture.work_order < fixture.remove_order && fixture.removals == 1;
}
static bool remove_running(bool timer)
{
    if (timer) {
        struct ieee80211_channel_switch request = switch_request();
        mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
    }
    fixture_arm_gate(timer ? G_TIMER_RUNNING : G_WORK_RUNNING);
    pthread_t callback = timer ? expire_timer() : start(work_callback); fixture_wait_gate();
    pthread_t remover = start(remove_callback); fixture_wait_counter(&fixture.sync_waits, 1);
    bool waited = !fixture.destroyed && !fixture.removals;
    failed(); fixture_release_gate(); join(callback); join(remover);
    return waited && fixture.destroyed && clean() && fixture.timer_order < fixture.work_order &&
           fixture.work_order < fixture.remove_order;
}
static bool remove_running_timer(void) { return remove_running(true); }
static bool remove_running_work(void) { return remove_running(false); }
static bool abort_cleanup(void)
{
    mvif()->csa_timer.queued = true; mvif()->csa_work.queued = true;
    mutex_lock(&fixture.wiphy.mtx);
    mt7921_abort_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &fixture.sdata.vif.bss_conf);
    destroy_interface(); mutex_unlock(&fixture.wiphy.mtx);
    return fixture.timer_joins == 2 && fixture.work_joins == 2 && clean();
}
static bool unassign_cleanup(void)
{
    mvif()->csa_timer.queued = true; mvif()->csa_work.queued = true;
    mutex_lock(&fixture.wiphy.mtx);
    mt792x_unassign_vif_chanctx(&fixture.local.hw, &fixture.sdata.vif,
                              &fixture.sdata.vif.bss_conf, &fixture.context);
    bool cleared = !mvif()->bss_conf.mt76.ctx;
    destroy_interface(); mutex_unlock(&fixture.wiphy.mtx);
    return cleared && fixture.timer_joins == 2 && fixture.work_joins == 2 && clean();
}
static void *down_after_leave(void *unused)
{
    (void)unused; mutex_lock(&fixture.wiphy.mtx);
    /* cfg80211 station leave has already cleared assoc; model only down stages. */
    fixture.sdata.vif.cfg.assoc = false;
    synchronize_rcu(); ieee80211_mgd_stop(&fixture.sdata);
    ieee80211_mgd_stop_link(&fixture.sdata.deflink);
    destroy_interface(); mutex_unlock(&fixture.wiphy.mtx); return NULL;
}
static bool rcu_completion_before_leave(void)
{
    struct ieee80211_channel_switch request = switch_request();
    mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request); failed();
    fixture_arm_gate(G_READ_ACTIVE); pthread_t completion = expire_timer(); fixture_wait_gate();
    bool old_reader = fixture.rcu_readers == 1;
    pthread_t down = start(down_after_leave); fixture_wait_counter(&fixture.grace_waits, 1);
    bool blocked = !fixture.destroyed && !fixture.removals;
    fixture_release_gate(); join(completion); join(down);
    return old_reader && blocked && fixture.notifications == 1 && !pending_drop() && fixture.destroyed && clean();
}
static bool completion_after_leave(void)
{
    fixture.sdata.vif.cfg.assoc = false;
    mt792x_csa_complete(mvif(), false);
    return !fixture.notifications && !pending_drop();
}
static bool mt7925_timer(void)
{
    fixture.dev.mt76.chip = 0x7925; failed(); mt792x_csa_timer(&mvif()->csa_timer);
    return mvif()->csa_work.queued && !fixture.notifications && clean();
}
static bool healthy_error(void)
{
    fixture.mcu_result = -EIO; mt7921_csa_work(&mvif()->csa_work);
    return fixture.mcu == 1 && fixture.pm_wakes == 1 && fixture.pm_releases == 1 && completed_failure();
}
static bool core_producer_terminal(void)
{
    fixture.sdata.vif.bss_conf.csa_active = false;
    fixture.sdata.deflink.u.mgd.csa.blocked_tx = false;
    fixture_arm_gate(G_CORE_PRODUCE); pthread_t core = start(core_start_csa); fixture_wait_gate();
    bool active_before_driver = fixture.sdata.vif.bss_conf.csa_active && fixture.sdata.deflink.u.mgd.csa.blocked_tx;
    failed(); fixture_release_gate(); join(core);
    return active_before_driver && !mvif()->csa_timer.queued && completed_failure();
}
static bool healthy_core_producer(void)
{
    fixture.sdata.vif.bss_conf.csa_active = false;
    fixture.sdata.deflink.u.mgd.csa.blocked_tx = false; join(start(core_start_csa));
    return mvif()->csa_timer.queued && fixture.sdata.vif.bss_conf.csa_active &&
           fixture.sdata.deflink.u.mgd.csa.blocked_tx && !pending_drop();
}
static bool normal_bus_csa(void)
{
    struct ieee80211_channel_switch request = switch_request();
    mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
    bool armed_once = mvif()->csa_timer.queued;
    join(expire_timer()); bool queued_once = mvif()->csa_work.queued;
    join(start(work_callback));
    mutex_lock(&fixture.wiphy.mtx); destroy_interface(); mutex_unlock(&fixture.wiphy.mtx);
    return armed_once && queued_once && fixture.mcu == 1 && fixture.pm_wakes == 2 &&
           fixture.removals == 1 && fixture.destroyed && clean();
}
static int cancel_kind;
static void *cancel_callback(void *unused)
{
    (void)unused; mutex_lock(&fixture.wiphy.mtx);
    if (cancel_kind == 1)
        mt7921_abort_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &fixture.sdata.vif.bss_conf);
    else
        mt792x_unassign_vif_chanctx(&fixture.local.hw, &fixture.sdata.vif,
                                  &fixture.sdata.vif.bss_conf, &fixture.context);
    destroy_interface(); mutex_unlock(&fixture.wiphy.mtx); return NULL;
}
static bool running_cancel(int kind, bool timer)
{
    cancel_kind = kind;
    if (timer) {
        struct ieee80211_channel_switch request = switch_request();
        mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
    }
    fixture_arm_gate(timer ? G_TIMER_RUNNING : G_WORK_RUNNING);
    pthread_t callback = timer ? expire_timer() : start(work_callback); fixture_wait_gate();
    pthread_t cancel = start(cancel_callback); fixture_wait_counter(&fixture.sync_waits, 1);
    bool waited = !fixture.destroyed;
    failed(); fixture_release_gate(); join(callback); join(cancel);
    return waited && fixture.destroyed && clean() && fixture.timer_joins == 2 && fixture.work_joins == 2;
}
static bool abort_running_timer(void) { return running_cancel(1, true); }
static bool abort_running_work(void) { return running_cancel(1, false); }
static bool unassign_running_work(void) { return running_cancel(2, false); }
static bool healthy_remove(void)
{
    mvif()->csa_timer.queued = true; mvif()->csa_work.queued = true;
    join(start(remove_callback));
    return fixture.destroyed && fixture.timer_joins == 1 && fixture.work_joins == 1 && fixture.removals == 1 && clean();
}
static bool nonstation_remove(void) { fixture.sdata.vif.type = NL80211_IFTYPE_AP; return healthy_remove(); }
static int reject_add(struct ieee80211_hw *hw, struct ieee80211_vif *vif)
{
    (void)hw; (void)vif; return -EIO;
}
static bool failed_add_no_remove(void)
{
    fixture.sdata.flags = 0; memset(fixture.sdata.vif.drv_priv, 0, sizeof(fixture.sdata.vif.drv_priv));
    fixture.ops.add_interface = reject_add;
    mutex_lock(&fixture.wiphy.mtx);
    int error = drv_add_interface(&fixture.local, &fixture.sdata);
    destroy_interface(); mutex_unlock(&fixture.wiphy.mtx);
    return error == -EIO && !fixture.sdata.flags && !fixture.removals && !fixture.timer_joins && !fixture.work_joins && clean();
}
static bool removed_timer(void)
{
    set_bit(MT76_REMOVED, &fixture.dev.mphy.state); mt792x_csa_timer(&mvif()->csa_timer);
    return !mvif()->csa_work.queued && completed_failure();
}
static bool removed_work(void)
{
    set_bit(MT76_REMOVED, &fixture.dev.mphy.state); mt7921_csa_work(&mvif()->csa_work);
    return !fixture.mcu && !fixture.pm_wakes && !fixture.pm_releases && completed_failure();
}
static bool removed_producer(void)
{
    set_bit(MT76_REMOVED, &fixture.dev.mphy.state); struct ieee80211_channel_switch request = switch_request();
    mt7921_channel_switch(&fixture.local.hw, &fixture.sdata.vif, &request);
    return !mvif()->csa_timer.queued && completed_failure();
}
static bool removed_rx(void)
{
    set_bit(MT76_REMOVED, &fixture.dev.mphy.state); struct ieee80211_channel_switch request = switch_request();
    mt7921_channel_switch_rx_beacon(&fixture.local.hw, &fixture.sdata.vif, &request);
    return !mvif()->csa_timer.queued && completed_failure();
}
static bool inactive_unassign(void)
{
    fixture.sdata.vif.bss_conf.csa_active = false;
    mvif()->csa_timer.queued = true; mvif()->csa_work.queued = true;
    mutex_lock(&fixture.wiphy.mtx);
    mt792x_unassign_vif_chanctx(&fixture.local.hw, &fixture.sdata.vif,
                              &fixture.sdata.vif.bss_conf, &fixture.context);
    bool conditional_skip = !fixture.timer_joins && !fixture.work_joins && !mvif()->bss_conf.mt76.ctx;
    destroy_interface(); mutex_unlock(&fixture.wiphy.mtx);
    return conditional_skip && fixture.timer_joins == 1 && fixture.work_joins == 1 && clean();
}
static bool usb_csa(void) { fixture.dev.mt76.bus = 1; return normal_bus_csa(); }
static bool sdio_csa(void) { fixture.dev.mt76.bus = 2; return normal_bus_csa(); }
