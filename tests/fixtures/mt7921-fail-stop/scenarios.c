/* Given fixed original source, observe behavior; compilation failure is never red evidence. */
#include "actual-source.c"

static struct mt792x_dev device;
static struct ieee80211_hw hardware;
static int ran, passed, failed;

static void given_device(void)
{
#ifdef WIRELESS_PATCHED
    fixture_device_init(&device, &hardware);
#else
    memset(&device, 0, sizeof(device));
    memset(&observed, 0, sizeof(observed));
    hardware.priv = &device.mphy;
    device.mphy.hw = &hardware;
    device.mphy.dev = &device.mt76;
    device.phy.mt76 = &device.mphy;
    set_bit(MT76_STATE_RUNNING, &device.mphy.state);
#endif
}

static bool normal_recovery(int success_at)
{
    given_device();
    observed.success_at = success_at;
    mt7921_mac_reset_work(&device.reset_work);
    return observed.attempts == success_at && observed.wakes == 1 &&
        observed.interfaces == 1 && !device.hw_full_reset &&
        !test_bit(MT76_RESET, &device.mphy.state);
}

static bool exhausted_stays_stopped(void)
{
    given_device();
    set_bit(MT76_HW_SCANNING, &device.mphy.state);
    mt7921_mac_reset_work(&device.reset_work);
    printf("TRACE exhausted: attempts=%d wakes=%d interfaces=%d ps=%d scan_aborts=%d\n",
        observed.attempts, observed.wakes, observed.interfaces,
        observed.ps_schedules, observed.scan_aborts);
    return observed.attempts == 10 && observed.wakes == 0 &&
        observed.interfaces == 0 && observed.ps_schedules == 0 &&
        observed.scan_aborts == 1 && !device.hw_full_reset;
}

static bool ownership_error_does_not_wake(void)
{
    given_device();
    observed.ownership_error = -EIO;
#ifdef WIRELESS_PATCHED
    set_bit(MT76_STATE_PM, &device.mphy.state);
#endif
    mt792x_pm_wake_work(&device.pm.wake_work);
    printf("TRACE PM ownership error: wakes=%d waiter_wakes=%d napi=%d\n",
        observed.wakes, observed.waiter_wakes, observed.napi_schedules);
    return observed.wakes == 0 && observed.waiter_wakes == 1;
}

#ifdef WIRELESS_PATCHED
/* Given a terminal instance, every late periodic entry must remain finite. */
static bool terminal_reentries(void)
{
    given_device();
    mt7921_mac_reset_work(&device.reset_work);
    int before = observed.resets;
    mt792x_reset(&device.mt76);
    mt7921_mac_reset_work(&device.reset_work);
    mt792x_pm_wake_work(&device.pm.wake_work);
    mt792x_pm_power_save_work(&device.pm.ps_work.work);
    mt792x_mac_work(&device.mphy.mac_work.work);
    mt792x_tx_worker(&device.mt76.tx_worker);
    mt7921_coredump_work(&device.coredump.work.work);
    return observed.resets == before && observed.wakes == 0 &&
        fixture_no_driver_periodic_work(&device) &&
        !device.hw_full_reset && !test_bit(MT76_RESET, &device.mphy.state);
}

/* Given a terminal transport, wait and non-wait commands consume one skb. */
static bool terminal_mcu_requests(void)
{
    for (int removed = 0; removed < 2; removed++) {
        for (int wait = 0; wait < 2; wait++) {
            given_device();
            set_bit(removed ? MT76_REMOVED : MT76_STATE_RECOVERY_FAILED, &device.mphy.state);
            struct sk_buff *request = fixture_skb();
            int ret = mt76_mcu_skb_send_and_get_msg(&device.mt76, request, 1, wait, NULL);
            if (ret != -EIO || request->consumed != 1 || observed.mcu_enqueues || observed.logs || observed.resets)
                return false;
        }
    }
    return true;
}

static bool healthy_mcu_requests(void)
{
    for (int wait = 0; wait < 2; wait++) {
        given_device();
        struct sk_buff *request = fixture_skb();
        int ret = mt76_mcu_skb_send_and_get_msg(&device.mt76, request, 1, wait, NULL);
        if (ret || request->consumed != 1 || observed.mcu_enqueues != 1)
            return false;
    }
    return true;
}

/* When FAILED wakes a sender already waiting under mcu.mutex, it exits without timeout/reset. */
static bool in_flight_mcu_waiter(void)
{
    given_device();
    fixture_hold_mcu_response();
    pthread_t sender = fixture_start_mcu_sender(&device);
    fixture_wait_until_mcu_waiting();
    /* Inject the actual exhaustion callback after all HIF attempts returned;
     * a transient per-attempt MCU_RESET is a different recovery partition. */
    pthread_t isolation = fixture_start_failed_transition(&device);
    fixture_join(sender);
    fixture_join(isolation);
    return fixture_sender_result() == -EIO && observed.mcu_enqueues == 1 &&
        observed.logs == 0 && observed.resets == 0 && fixture_mcu_request_consumed_once();
}

/* NAPI disable/enable remains balanced at every real PCIe reset error exit. */
static bool pcie_reset_error_partitions(void)
{
    for (int stage = STAGE_WPDMA; stage <= STAGE_START; stage++) {
        given_device();
        observed.failure_stage = stage;
        mt76_worker_disable(&device.mt76.tx_worker);
        int ret = mt7921e_mac_reset(&device);
        if (ret != -EIO || observed.wpdma_calls != 1 || !fixture_napi_enabled(&device) ||
            observed.tx_napi_schedules || observed.unparks || observed.locked_waits)
            return false;
    }
    given_device();
    observed.ownership_error = -EIO;
    observed.success_at = 1;
    mt76_worker_disable(&device.mt76.tx_worker);
    return mt7921e_mac_reset(&device) == 0 && observed.wpdma_calls == 1 &&
        fixture_napi_enabled(&device) && observed.tx_napi_schedules == 1;
}

static bool terminal_mac80211_pm(void)
{
    for (int removed = 0; removed < 2; removed++) {
        given_device();
        set_bit(removed ? MT76_REMOVED : MT76_STATE_RECOVERY_FAILED, &device.mphy.state);
        if (mt7921_suspend(&hardware, NULL) || mt7921_resume(&hardware) ||
            test_bit(MT76_STATE_RUNNING, &device.mphy.state) || observed.interfaces ||
            observed.runtime_commands || !fixture_no_driver_periodic_work(&device))
            return false;
    }
    return true;
}

static bool healthy_mac80211_pm(void)
{
    for (int power_save = 0; power_save < 2; power_save++) {
        given_device();
        device.pm.enable = power_save;
        observed.success_at = 1;
        if (mt7921_suspend(&hardware, NULL) || test_bit(MT76_STATE_RUNNING, &device.mphy.state))
            return false;
        if (mt7921_resume(&hardware) || !test_bit(MT76_STATE_RUNNING, &device.mphy.state))
            return false;
        /* Original normal release schedules PS instead of the watchdog when
         * PM is enabled. Both original health partitions must remain intact. */
        if (observed.interfaces != 2 ||
            (power_save ? !device.pm.ps_work.work.pending : !device.mphy.mac_work.work.pending))
            return false;
    }
    return true;
}

/* Publish FAILED first; do not complete the barrier while an older callback owns mt76.mutex. */
static bool old_pm_callback_barrier(void)
{
    given_device();
    fixture_hold_interface_iteration();
    pthread_t resume = fixture_start_mac_resume(&hardware);
    fixture_wait_until_interface_iteration();
    /* The tenth HIF attempt has returned: a new PM callback can own the mutex
     * before common reset calls its registered failure callback. Do not force
     * an entire PCIe reset through a mutex held by the old callback. */
    pthread_t reset = fixture_start_failed_transition(&device);
    fixture_wait_until_failed_published(&device);
    if (!fixture_reset_waits_for_mt76())
        return false;
    fixture_release_interface_iteration();
    fixture_join(resume);
    fixture_join(reset);
    return !test_bit(MT76_STATE_RUNNING, &device.mphy.state) &&
        !device.mphy.mac_work.work.pending && observed.wakes == 0;
}

/* The real complete clears SCHED but leaves the C function tail alive. */
static bool napi_complete_tail_interleavings(void)
{
    for (int rx = 0; rx < 2; rx++) {
        given_device();
        fixture_hold_napi_complete_tail();
        pthread_t poll = fixture_start_poll(&device, rx);
        fixture_wait_until_complete_tail();
        mt7921_mac_reset_work(&device.reset_work);
        fixture_release_napi_complete_tail();
        fixture_join(poll);
        if (device.mt76.mmio.irqmask || device.mt76.irq_tasklet.pending ||
            !fixture_no_driver_periodic_work(&device) || observed.after_failed_irq_enables)
            return false;
    }
    return true;
}

/* Queued-but-not-running is owned by poll, for both SMP synchronization APIs. */
static bool queued_tx_synchronize(void) { given_device(); return fixture_queued_napi_waits(&device.mt76.tx_napi,false); }
static bool queued_rx_synchronize(void) { given_device(); return fixture_queued_napi_waits(&device.mt76.napi[0],false); }
static bool queued_tx_disable(void) { given_device(); return fixture_queued_napi_waits(&device.mt76.tx_napi,true); }
static bool queued_rx_disable(void) { given_device(); return fixture_queued_napi_waits(&device.mt76.napi[0],true); }

/* If the IRQ helper got the lock first, FAILED publication waits, then collects its tasklet. */
static bool irq_helper_before_failed(void)
{
    given_device();
    fixture_hold_irq_healthy_check();
    pthread_t enable = fixture_start_irq_enable(&device);
    fixture_wait_until_irq_healthy_check();
    pthread_t reset = fixture_start_reset(&device);
    fixture_wait_until_failed_waits_irq_lock();
    fixture_release_irq_healthy_check();
    fixture_join(enable);
    fixture_join(reset);
    return device.mt76.mmio.irqmask == 0 && !device.mt76.irq_tasklet.pending &&
        observed.irq_schedule_outside_lock == 0;
}

/* Actual framework poll requeues even if the terminal driver callback only returns. */
static bool healthy_and_early_return_polling(void)
{
    given_device();
    if (__mt7921_start(&device.phy))
        return false;
    fixture_run_rfkill_poll(&device);
    if (!fixture_rfkill_poll_pending(&device) || observed.rfkill_commands < 2)
        return false;
    set_bit(MT76_STATE_RECOVERY_FAILED, &device.mphy.state);
    int before = observed.rfkill_commands;
    fixture_run_rfkill_poll(&device);
    return observed.rfkill_commands == before && fixture_rfkill_poll_pending(&device);
}

/* Last-interface stop owns wiphy; reset and a running framework poll must both progress. */
static bool rfkill_three_party_progress(void)
{
    given_device();
    fixture_start_rfkill_polling(&device);
    fixture_hold_last_reset_attempt();
    pthread_t reset = fixture_start_reset(&device);
    fixture_wait_until_last_reset_attempt();
    pthread_t stop = fixture_start_last_interface_stop(&device);
    fixture_wait_until_stop_waits_reset();
    pthread_t poll = fixture_start_running_rfkill_poll(&device);
    fixture_wait_until_poll_waits_wiphy();
    fixture_release_last_reset_attempt();
    fixture_join(reset);
    fixture_join(stop);
    fixture_join(poll);
    fixture_run_rfkill_cleanup(&device);
    printf("TRACE rfkill: paused=%d pending=%d running=%d queued=%d wrong_queue=%d reset_join=%d stop_join=%d late_mcu=%d\n",
        fixture_rfkill.polling_paused, fixture_rfkill.poll_work.work.pending,
        fixture_rfkill.poll_work.work.running, observed.rfkill_work_queues,
        observed.rfkill_work_wrong_queue, observed.reset_joins_rfkill,
        observed.stop_joins_rfkill, observed.runtime_commands_after_failed);
    return fixture_rfkill_quiet(&device) && observed.rfkill_work_queues == 1 &&
        observed.rfkill_work_wrong_queue == 0 && observed.reset_joins_rfkill == 0 &&
        observed.stop_joins_rfkill == 0 && observed.runtime_commands_after_failed == 0;
}

/* Removal must join the sole producer before flushing cleanup, never free its wiphy first. */
static bool removal_producer_and_cleanup_partitions(void)
{
    for (int point = REMOVE_BEFORE_LAST_QUEUE; point <= REMOVE_RUNNING_CLEANUP; point++) {
        given_device();
        fixture_start_rfkill_polling(&device);
        if (!fixture_remove_interleaving(&device, point))
            return false;
        if (!fixture_rfkill_quiet(&device) || observed.callback_after_free ||
            observed.flush_before_producer_join || observed.free_before_rfkill_join)
            return false;
    }
    return true;
}

static bool no_rfkill_owner_partitions(void)
{
    given_device();
    device.phy.chip_cap = 0;
    mt7921_mac_reset_work(&device.reset_work);
    if (observed.rfkill_work_queues)
        return false;
    for (int probe_error = PROBE_FIRST_DEVICE_ERROR; probe_error <= PROBE_LAST_DEVICE_ERROR; probe_error++) {
        given_device();
        observed.probe_failure = probe_error;
        if (fixture_real_probe(&device) == 0 || observed.join_uninitialized_work ||
            observed.rfkill_work_queues || observed.device_frees != 1)
            return false;
    }
    given_device();
    mt7921e_unregister_device(&device);
    return observed.rfkill_work_queues == 0 && fixture_rfkill_quiet(&device);
}

static bool stop_led_error_keeps_software_cleanup(void)
{
    given_device();
    observed.led_error = -EIO;
    fixture_add_pending_pm_skb(&device);
    mt7921_stop(&hardware, false);
    return !test_bit(MT76_STATE_RUNNING, &device.mphy.state) &&
        observed.pm_skb_frees == 1 && observed.reset_sync_cancels == 1;
}

static bool failed_stop_remove_resources(void)
{
    for (int shutdown = 0; shutdown < 2; shutdown++) {
        given_device();
        fixture_add_pending_pm_skb(&device);
        mt7921_mac_reset_work(&device.reset_work);
        mt7921_stop(&hardware, false);
        int ownership_before = observed.ownership_calls;
        int wfsys_before = observed.wfsys_calls;
        if (shutdown)
            mt7921_pci_shutdown(&fixture_pci);
        else
            mt7921_pci_remove(&fixture_pci);
        if (observed.parks != 1 || observed.unparks != 0 || observed.device_frees != 1 ||
            observed.ownership_calls != ownership_before || observed.wfsys_calls != wfsys_before ||
            !fixture_all_dma_resources_released(&device) || !fixture_rfkill_quiet(&device))
            return false;
    }
    return true;
}

static bool terminal_bus_pm_and_start(void)
{
    given_device();
    mt7921_mac_reset_work(&device.reset_work);
    int commands = observed.runtime_commands;
    if (__mt7921_start(&device.phy) != -EIO || mt7921_pci_suspend(&fixture_pci.dev) ||
        mt7921_pci_resume(&fixture_pci.dev))
        return false;
    return observed.runtime_commands == commands && observed.wakes == 0 &&
        device.mt76.mmio.irqmask == 0 && fixture_napi_enabled(&device);
}

static bool terminal_deferred_software_cleanup(void)
{
    given_device();
    fixture_seed_deferred_resources(&device);
    mt7921_mac_reset_work(&device.reset_work);
    mt7921_scan_work(&device.phy.scan_work.work);
    mt7921_roc_work(&device.phy.roc_work);
    /* Per-vif CSA uses the existing complete-source CSA partition, not reset. */
    mt7921_set_ipv6_ns_work(&device.ipv6_ns_work);
    mt7921_coredump_work(&device.coredump.work.work);
    mt792x_roc_timer(&device.phy.roc_timer);
    return fixture_deferred_resources_released(&device) && observed.scan_aborts == 1 &&
        observed.runtime_commands_after_failed == 0 && fixture_no_driver_periodic_work(&device);
}

static bool non_pcie_recovery_compatibility(void)
{
    given_device();
    fixture_without_pcie_callback(&device);
    mt7921_mac_reset_work(&device.reset_work);
    return observed.attempts == 10 && observed.wakes == 1 && observed.interfaces == 1 &&
        !test_bit(MT76_STATE_RECOVERY_FAILED, &device.mphy.state) && observed.parks == 0;
}
#endif

static void result(const char *name, bool ok)
{
    ran++;
    passed += ok;
    failed += !ok;
    printf("%s %s\n", ok ? "PASS" : "FAIL", name);
}

static bool first_attempt(void) { return normal_recovery(1); }
static bool middle_attempt(void) { return normal_recovery(5); }
static bool tenth_attempt(void) { return normal_recovery(10); }

static void execute(const char *name, bool (*scenario)(void))
{
#ifdef WIRELESS_PATCHED
    fflush(NULL);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) { alarm(15); bool ok = scenario(); fflush(NULL); _exit(ok ? 0 : 1); }
    int status;
    assert(waitpid(child, &status, 0) == child);
    if (WIFSIGNALED(status)) fprintf(stderr, "SIGNAL %s signal=%d\n", name, WTERMSIG(status));
    result(name, WIFEXITED(status) && WEXITSTATUS(status) == 0);
#else
    result(name, scenario());
#endif
}

int main(void)
{
    /* Given recovery at the exact bound, it is success, not exhaustion. */
    execute("recovery succeeds first attempt", first_attempt);
    execute("recovery succeeds middle attempt", middle_attempt);
    execute("recovery succeeds tenth attempt", tenth_attempt);
    /* When all attempts fail, then queues/interfaces/PS must remain stopped. */
    execute("exhausted recovery does not revive interfaces", exhausted_stays_stopped);
    /* When PM ownership fails, then wake waiters, not data queues. */
    execute("PM ownership error does not wake queues", ownership_error_does_not_wake);
    int expected = 5;
#ifdef WIRELESS_PATCHED
    struct scenario { const char *name; bool (*run)(void); } cases[] = {
        {"terminal late periodic reentries", terminal_reentries},
        {"terminal MCU wait/nonwait and REMOVED", terminal_mcu_requests},
        {"healthy MCU commands", healthy_mcu_requests},
        {"in-flight MCU waiter is woken before mutex drain", in_flight_mcu_waiter},
        {"PCIe reset error exits balance NAPI", pcie_reset_error_partitions},
        {"terminal mac80211 suspend/resume", terminal_mac80211_pm},
        {"healthy mac80211 suspend/resume", healthy_mac80211_pm},
        {"older PM callback drained before isolation completes", old_pm_callback_barrier},
        {"TX/RX NAPI complete does not end poll tail", napi_complete_tail_interleavings},
        {"queued TX synchronize waits for actual poll", queued_tx_synchronize},
        {"queued RX synchronize waits for actual poll", queued_rx_synchronize},
        {"queued TX disable waits for actual poll", queued_tx_disable},
        {"queued RX disable waits for actual poll", queued_rx_disable},
        {"IRQ helper lock winner drained by FAILED", irq_helper_before_failed},
        {"healthy framework polling and early-return counterexample", healthy_and_early_return_polling},
        {"rfkill stop/reset/poll three-party progress", rfkill_three_party_progress},
        {"removal joins producer then queued/running cleanup", removal_producer_and_cleanup_partitions},
        {"capability-off probe-errors and healthy remove", no_rfkill_owner_partitions},
        {"LED error still runs software stop", stop_led_error_keeps_software_cleanup},
        {"FAILED stop/remove releases DMA without repark", failed_stop_remove_resources},
        {"terminal PCI PM and start do not resurrect hardware", terminal_bus_pm_and_start},
        {"terminal deferred work frees software resources", terminal_deferred_software_cleanup},
        {"non-PCIe recovery preserves previous semantics", non_pcie_recovery_compatibility},
    };
    expected += (int)(sizeof(cases) / sizeof(cases[0]));
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); index++)
        execute(cases[index].name, cases[index].run);
#endif
    printf("ran=%d passed=%d failed=%d expected=%d\n", ran, passed, failed, expected);
    if (ran != expected || expected < 5)
        return 2;
    return failed ? 1 : 0;
}
