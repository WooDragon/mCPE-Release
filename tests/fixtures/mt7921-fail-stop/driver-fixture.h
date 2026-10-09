/* Controlled schedules around the real complete driver and rfkill functions. */
#ifndef DRIVER_FIXTURE_H
#define DRIVER_FIXTURE_H
static struct mt792x_hif_ops fixture_hif;
static const struct mt792x_irq_map fixture_irq={ .host_irq_enable=MT_WFDMA0_HOST_INT_ENA,
    .tx={1,2}, .rx={4,8,16} };
static struct mt76_mcu_ops fixture_mcu_ops;
static bool fixture_initialized;

static void fixture_device_init(struct mt792x_dev *dev, struct ieee80211_hw *hw)
{
    if (fixture_initialized) {
        struct mutex *old[]={ &dev->mt76.mutex,&dev->mt76.lock,&dev->mt76.mcu.mutex,
            &dev->mt76.mmio.irq_lock,&dev->pm.mutex,&dev->pm.txq_lock,&dev->pm.wake.lock,&fixture_rdev.wiphy.mtx };
        for (unsigned index=0;index<ARRAY_SIZE(old);index++) { assert(!old[index]->owner); pthread_mutex_destroy(&old[index]->real); }
    }
    memset(dev,0,sizeof(*dev)); memset(&observed,0,sizeof(observed));
    memset(&fixture_local,0,sizeof(fixture_local)); memset(&fixture_rdev,0,sizeof(fixture_rdev));
    memset(&fixture_rfkill,0,sizeof(fixture_rfkill)); memset(&fixture_pci,0,sizeof(fixture_pci));
    memset(fixture_tx,0,sizeof(fixture_tx)); memset(fixture_mcu,0,sizeof(fixture_mcu));
    current_device=dev; identity=1; next_identity=1; role=ROLE_MAIN;
    memset(waiting,0,sizeof(waiting)); memset(joining,0,sizeof(joining));
    armed_gate=arrived_gate=G_NONE; hold_response=false; device_freed=false;
    producer_joined=cleanup_joined=false; skb_used=0;
    hold_napi_dispatch=napi_sync_waiting=napi_sync_done=false; napi_poll_calls=0;
    mutex_init(&dev->mt76.mutex,"mt76"); mutex_init(&dev->mt76.lock,"skb");
    mutex_init(&dev->mt76.mcu.mutex,"mcu"); mutex_init(&dev->mt76.mmio.irq_lock,"irq");
    mutex_init(&dev->pm.mutex,"pm"); mutex_init(&dev->pm.txq_lock,"txq");
    mutex_init(&dev->pm.wake.lock,"wake"); mutex_init(&fixture_rdev.wiphy.mtx,"wiphy");
    hw->priv=&dev->mphy; hw->wiphy=&fixture_rdev.wiphy;
    fixture_local.hw=*hw; fixture_local.started=true;
    mt7921_ops.stop=mt7921_stop; mt7921_ops.rfkill_poll=mt7921_rfkill_poll;
    fixture_local.ops=&mt7921_ops; fixture_rdev.wiphy.local=&fixture_local;
    cfg_ops.rfkill_poll=ieee80211_rfkill_poll; fixture_rdev.ops=&cfg_ops;
    fixture_rdev.rfkill_ops.poll=cfg80211_rfkill_poll;
    fixture_rdev.wiphy.rfkill=&fixture_rfkill;
    fixture_rfkill.ops=&fixture_rdev.rfkill_ops; fixture_rfkill.data=&fixture_rdev;
    fixture_rfkill.registered=true; fixture_rfkill.persistent=true; fixture_rfkill.polling_paused=true;
    work_init(&fixture_rfkill.poll_work.work,rfkill_poll,"framework-poll");
    dev->mphy.hw=hw; dev->mphy.dev=&dev->mt76; dev->mphy.priv=&dev->phy;
    dev->phy.mt76=&dev->mphy; dev->phy.dev=dev;
    dev->phy.chip_cap=MT792x_CHIP_CAP_WF_RF_PIN_CTRL_EVT_EN;
    dev->hw_init_done=true; dev->pm.enable=true; dev->pm.idle_timeout=100;
    dev->mt76.rev=0x79220000; dev->mt76.dev=&fixture_pci.dev; fixture_pci.data=&dev->mt76; fixture_pci.irq=1;
    dev->mt76.wq=&queue_ordered;
    fixture_hif=(struct mt792x_hif_ops){ .reset=mt7921e_mac_reset,.reset_failed=mt7921e_reset_failed,
        .drv_own=mt792xe_mcu_drv_pmctrl,.fw_own=mt792xe_mcu_fw_pmctrl };
    dev->hif_ops=&fixture_hif; dev->irq_map=&fixture_irq;
    fixture_mcu_ops=(struct mt76_mcu_ops){ .mcu_skb_send_msg=mt7921_mcu_send_message,.mcu_parse_response=mt7921_mcu_parse_response };
    dev->mt76.mcu_ops=&fixture_mcu_ops; dev->mt76.mcu.timeout=3*HZ;
    work_init(&dev->reset_work,mt7921_mac_reset_work,"reset");
    work_init(&dev->rfkill_work,mt7921e_rfkill_stop_work,"rfkill-cleanup");
    work_init(&dev->init_work,NULL,"init"); work_init(&dev->mphy.mac_work.work,mt792x_mac_work,"watchdog");
    work_init(&dev->pm.ps_work.work,mt792x_pm_power_save_work,"ps");
    work_init(&dev->pm.wake_work,mt792x_pm_wake_work,"wake");
    work_init(&dev->phy.scan_work.work,mt7921_scan_work,"scan");
    work_init(&dev->phy.roc_work,mt7921_roc_work,"roc");
    work_init(&dev->coredump.work.work,mt7921_coredump_work,"coredump");
    work_init(&dev->ipv6_ns_work,mt7921_set_ipv6_ns_work,"ipv6");
    for (int index=0;index<3;index++) { dev->mt76.napi[index].enabled=true; dev->mt76.napi[index].dev=dev; dev->mt76.q_rx[index].page_pool=&dev->mt76.q_rx[index]; }
    dev->mt76.tx_napi.enabled=true; dev->mt76.tx_napi.dev=dev;
    dev->mt76.phys[0]=&dev->mphy;
    for (int index=0;index<2;index++) { dev->mphy.q_tx[index]=&fixture_tx[index]; dev->mt76.q_mcu[index]=&fixture_mcu[index]; }
    set_bit(MT76_STATE_RUNNING,&dev->mphy.state); set_bit(MT76_STATE_MCU_RUNNING,&dev->mphy.state);
    set_bit(MT76_STATE_INITIALIZED,&dev->mphy.state); fixture_initialized=true;
}
static bool fixture_napi_enabled(struct mt792x_dev *dev)
{
    for (int index=0;index<3;index++) if (!dev->mt76.napi[index].enabled) return false;
    return dev->mt76.tx_napi.enabled;
}
static bool fixture_no_driver_periodic_work(struct mt792x_dev *dev)
{
    return !dev->mphy.mac_work.work.pending && !dev->pm.ps_work.work.pending &&
        !dev->pm.wake_work.pending && !dev->reset_work.pending && !dev->coredump.work.work.pending;
}
static void fixture_join(pthread_t thread) { assert(!pthread_join(thread,NULL)); }
static void *reset_thread(void *pointer)
{
    struct mt792x_dev *dev=pointer; role=ROLE_RESET;
    work_begin(&dev->reset_work); mt7921_mac_reset_work(&dev->reset_work); work_end(&dev->reset_work); return NULL;
}
static void *failed_thread(void *pointer)
{
    struct mt792x_dev *dev=pointer; role=ROLE_RESET;
    work_begin(&dev->reset_work); mt7921e_reset_failed(dev); work_end(&dev->reset_work); return NULL;
}
static pthread_t start_thread(void *(*callback)(void *), void *argument)
{
    pthread_t thread; assert(!pthread_create(&thread,NULL,callback,argument)); return thread;
}
static pthread_t fixture_start_reset(struct mt792x_dev *dev) { return start_thread(reset_thread,dev); }
static pthread_t fixture_start_failed_transition(struct mt792x_dev *dev) { return start_thread(failed_thread,dev); }
static void fixture_hold_last_reset_attempt(void) { arm_gate(G_LAST_ATTEMPT); }
static void fixture_wait_until_last_reset_attempt(void) { wait_gate(G_LAST_ATTEMPT); }
static void fixture_release_last_reset_attempt(void) { release_gate(); }
static void fixture_hold_interface_iteration(void) { arm_gate(G_ITERATE); }
static void fixture_wait_until_interface_iteration(void) { wait_gate(G_ITERATE); }
static void fixture_release_interface_iteration(void) { release_gate(); }
static void *resume_thread(void *pointer) { role=ROLE_PM; mt7921_resume(pointer); return NULL; }
static pthread_t fixture_start_mac_resume(struct ieee80211_hw *hw) { return start_thread(resume_thread,hw); }
static void fixture_wait_until_failed_published(struct mt792x_dev *dev)
{
    pthread_mutex_lock(&events); while (!(atomic_load(&dev->mphy.state)&(1ul<<MT76_STATE_RECOVERY_FAILED))) pthread_cond_wait(&changed,&events); pthread_mutex_unlock(&events);
}
static bool thread_waits_lock(struct mutex *lock)
{
    for (int index=1;index<=atomic_load(&next_identity);index++) if (waiting[index]==lock) return true;
    return false;
}
static bool fixture_reset_waits_for_mt76(void)
{
    pthread_mutex_lock(&events);
    while (!thread_waits_lock(&current_device->mt76.mutex) && current_device->reset_work.running)
        pthread_cond_wait(&changed,&events);
    bool waiting_for_owner=thread_waits_lock(&current_device->mt76.mutex);
    pthread_mutex_unlock(&events); return waiting_for_owner;
}
static void fixture_hold_mcu_response(void) { hold_response=true; }
static void *mcu_thread(void *pointer)
{
    struct mt792x_dev *dev=pointer; role=ROLE_MCU; sender_request=fixture_skb();
    sender_result=mt76_mcu_skb_send_and_get_msg(&dev->mt76,sender_request,1,true,NULL); announce(); return NULL;
}
static pthread_t fixture_start_mcu_sender(struct mt792x_dev *dev) { return start_thread(mcu_thread,dev); }
static void fixture_wait_until_mcu_waiting(void)
{
    pthread_mutex_lock(&events); while (!observed.mcu_enqueues || !current_device->mt76.mcu.mutex.owner) pthread_cond_wait(&changed,&events); pthread_mutex_unlock(&events);
}
static int fixture_sender_result(void) { return sender_result; }
static bool fixture_mcu_request_consumed_once(void) { return sender_request->consumed==1; }
static void fixture_hold_napi_complete_tail(void) { arm_gate(G_NAPI_TAIL); }
static void fixture_wait_until_complete_tail(void) { wait_gate(G_NAPI_TAIL); }
static void fixture_release_napi_complete_tail(void) { release_gate(); }
static void *poll_napi_thread(void *pointer)
{
    struct napi_struct *napi=pointer; role=ROLE_POLL; napi->sched=true; napi->running=true;
    if (napi==&current_device->mt76.tx_napi) mt792x_poll_tx(napi,64); else mt792x_poll_rx(napi,64);
    napi->running=false; announce(); return NULL;
}
static pthread_t fixture_start_poll(struct mt792x_dev *dev, int rx) { return start_thread(poll_napi_thread,rx ? &dev->mt76.napi[0] : &dev->mt76.tx_napi); }
/* Run delivered synchronization APIs, with completion visible to the controller. */
struct napi_sync_request { struct napi_struct *napi; bool disable; };
static void *queued_napi_sync_thread(void *pointer)
{
    struct napi_sync_request *request=pointer;
    if (request->disable) napi_disable(request->napi); else napi_synchronize(request->napi);
    pthread_mutex_lock(&events);
    napi_sync_done=true; pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events); return NULL;
}
/* No sleeps: wait until the API either blocks on SCHED or incorrectly returns. */
static bool fixture_queued_napi_waits(struct napi_struct *napi, bool disable)
{
    struct napi_sync_request request={napi,disable};
    hold_napi_dispatch=true; napi_sync_waiting=false; napi_sync_done=false;
    napi_schedule(napi);
    pthread_t sync=start_thread(queued_napi_sync_thread,&request);
    pthread_mutex_lock(&events);
    while (!napi_sync_waiting && !napi_sync_done) pthread_cond_wait(&changed,&events);
    bool blocked=napi_sync_waiting && !napi_sync_done && napi->sched && !napi->running && napi->enabled;
    hold_napi_dispatch=false; pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events); fixture_join(sync);
    printf("TRACE queued NAPI: disable=%d blocked=%d polls=%d sched=%d enabled=%d\n",
        disable,blocked,napi_poll_calls,napi->sched,napi->enabled);
    return blocked && napi_poll_calls==1 && !napi->sched && !napi->running &&
        napi->enabled==!disable && napi->disables==disable;
}
static void fixture_hold_irq_healthy_check(void) { arm_gate(G_IRQ_CHECK); }
static void fixture_wait_until_irq_healthy_check(void) { wait_gate(G_IRQ_CHECK); }
static void fixture_release_irq_healthy_check(void) { release_gate(); }
static void *irq_thread(void *pointer) { role=ROLE_IRQ; mt76_connac_irq_enable(pointer,1); return NULL; }
static pthread_t fixture_start_irq_enable(struct mt792x_dev *dev) { return start_thread(irq_thread,&dev->mt76); }
static void fixture_wait_until_failed_waits_irq_lock(void)
{
    pthread_mutex_lock(&events); while (!thread_waits_lock(&current_device->mt76.mmio.irq_lock)) pthread_cond_wait(&changed,&events); pthread_mutex_unlock(&events);
}
static void fixture_start_rfkill_polling(struct mt792x_dev *dev) { wiphy_rfkill_start_polling(mt76_hw(dev)->wiphy); }
static void fixture_run_rfkill_poll(struct mt792x_dev *dev)
{
    (void)dev; struct work_struct *work=&fixture_rfkill.poll_work.work;
    work_begin(work); rfkill_poll(work); work_end(work);
}
static bool fixture_rfkill_poll_pending(struct mt792x_dev *dev) { (void)dev; return fixture_rfkill.poll_work.work.pending; }
static bool fixture_rfkill_quiet(struct mt792x_dev *dev)
{
    (void)dev;
    if (!fixture_rfkill.polling_paused || fixture_rfkill.poll_work.work.pending || fixture_rfkill.poll_work.work.running) return false;
    if (!device_freed) rfkill_resume(&fixture_rfkill.dev);
    return !fixture_rfkill.poll_work.work.pending;
}
static void fixture_run_rfkill_cleanup(struct mt792x_dev *dev) { flush_work(&dev->rfkill_work); }
static void *stop_thread(void *pointer)
{
    (void)pointer; role=ROLE_STOP; wiphy_lock(&fixture_rdev.wiphy);
    drv_stop(&fixture_local,false); wiphy_unlock(&fixture_rdev.wiphy); return NULL;
}
static pthread_t fixture_start_last_interface_stop(struct mt792x_dev *dev) { return start_thread(stop_thread,dev); }
static void fixture_wait_until_stop_waits_reset(void)
{
    pthread_mutex_lock(&events);
    while (true) { bool found=false; for (int index=1;index<=atomic_load(&next_identity);index++) found |= joining[index]==current_device->reset_work.owner && current_device->reset_work.running; if (found) break; pthread_cond_wait(&changed,&events); }
    pthread_mutex_unlock(&events);
}
static pthread_t fixture_start_running_rfkill_poll(struct mt792x_dev *dev) { (void)dev; return start_thread(run_work,&fixture_rfkill.poll_work.work); }
static void fixture_wait_until_poll_waits_wiphy(void)
{
    pthread_mutex_lock(&events); while (!thread_waits_lock(&fixture_rdev.wiphy.mtx)) pthread_cond_wait(&changed,&events); pthread_mutex_unlock(&events);
}
static void *remove_thread(void *pointer) { role=ROLE_REMOVE; mt7921e_unregister_device(pointer); return NULL; }
static bool fixture_remove_interleaving(struct mt792x_dev *dev, int point)
{
    if (point==REMOVE_BEFORE_LAST_QUEUE) {
        arm_gate(G_BEFORE_RFQUEUE); pthread_t reset=fixture_start_reset(dev); wait_gate(G_BEFORE_RFQUEUE);
        pthread_t removal=start_thread(remove_thread,dev);
        pthread_mutex_lock(&events); while (!test_bit(MT76_REMOVED,&dev->mphy.state)) pthread_cond_wait(&changed,&events); pthread_mutex_unlock(&events);
        assert(!cleanup_joined && !device_freed); release_gate(); fixture_join(reset); fixture_join(removal);
        return producer_joined && cleanup_joined && observed.cleanup_stops==1;
    }
    mt7921_mac_reset_work(&dev->reset_work);
    assert(dev->rfkill_work.pending);
    if (point==REMOVE_QUEUED_CLEANUP) {
        role=ROLE_REMOVE; mt7921e_unregister_device(dev); role=ROLE_MAIN;
        return producer_joined && cleanup_joined && observed.cleanup_stops==1;
    }
    wiphy_lock(&fixture_rdev.wiphy);
    pthread_t poll=fixture_start_running_rfkill_poll(dev); fixture_wait_until_poll_waits_wiphy();
    pthread_t cleanup=start_thread(run_work,&dev->rfkill_work);
    pthread_mutex_lock(&events); while (!dev->rfkill_work.running) pthread_cond_wait(&changed,&events); pthread_mutex_unlock(&events);
    pthread_t removal=start_thread(remove_thread,dev);
    pthread_mutex_lock(&events); while (!producer_joined) pthread_cond_wait(&changed,&events); pthread_mutex_unlock(&events);
    assert(!cleanup_joined && !device_freed); wiphy_unlock(&fixture_rdev.wiphy);
    fixture_join(poll); fixture_join(cleanup); fixture_join(removal); return producer_joined && cleanup_joined && observed.cleanup_stops==1;
}
static int fixture_real_probe(struct mt792x_dev *dev) { (void)dev; struct pci_device_id id={0}; return mt7921_pci_probe(&fixture_pci,&id); }
static void fixture_add_pending_pm_skb(struct mt792x_dev *dev)
{
    dev->pm.tx_q[0].skb=fixture_skb(); observed.pm_skb_frees=0;
}
static bool fixture_all_dma_resources_released(struct mt792x_dev *dev)
{
    if (observed.napi_deletes!=4 || observed.pages!=3 || observed.rings!=7 || !observed.txwi_frees || !observed.rxwi_frees || observed.tokens) return false;
    for (int index=0;index<3;index++) if (!dev->mt76.napi[index].deleted) return false;
    return dev->mt76.tx_napi.deleted;
}
static void fixture_seed_deferred_resources(struct mt792x_dev *dev)
{
    set_bit(MT76_HW_SCANNING,&dev->mphy.state); set_bit(MT76_STATE_ROC,&dev->mphy.state);
    dev->phy.scan_event_list.head=fixture_skb(); dev->coredump.msg_list.head=fixture_skb();
    dev->ipv6_ns_list.head=fixture_skb(); fixture_add_pending_pm_skb(dev);
    dev->pm.ps_work.work.pending=true; dev->coredump.work.work.pending=true;
    dev->phy.scan_work.work.pending=true; dev->phy.roc_work.pending=true;
}
static bool fixture_deferred_resources_released(struct mt792x_dev *dev)
{
    return !dev->phy.scan_event_list.head && !dev->coredump.msg_list.head && !dev->ipv6_ns_list.head && !dev->pm.tx_q[0].skb && !dev->phy.roc_timer.pending;
}
static int non_pcie_reset(struct mt792x_dev *dev) { (void)dev; observed.attempts++; return observed.attempts==observed.success_at ? 0 : -EIO; }
static void fixture_without_pcie_callback(struct mt792x_dev *dev) { fixture_hif.reset_failed=NULL; fixture_hif.reset=non_pcie_reset; dev->mt76.bus_kind=2; }
#endif
