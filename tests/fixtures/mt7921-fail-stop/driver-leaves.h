/* Hardware, allocation, packet and unrelated BSS leaves. Lifecycle functions
 * under test are extracted whole; no new production fail-stop helper is stubbed.
 */
#ifndef DRIVER_LEAVES_H
#define DRIVER_LEAVES_H
static bool mt7921_disable_aspm;
static struct ieee80211_ops mt7921_ops;
static struct cfg80211_ops cfg_ops;
static struct sk_buff skbs[128];
static unsigned skb_used;

static struct sk_buff *fixture_skb(void)
{
    assert(skb_used < ARRAY_SIZE(skbs));
    struct sk_buff *skb=&skbs[skb_used++]; memset(skb,0,sizeof(*skb));
    skb->data=skb->storage; skb->len=sizeof(struct mt76_connac2_mcu_rxd); skb->references=1;
    ((struct mt76_connac2_mcu_rxd *)skb->data)->seq=1;
    return skb;
}
static void dev_kfree_skb(struct sk_buff *skb)
{
    if (!skb) return;
    assert(skb->references > 0); skb->references--;
    if (!skb->references) {
        assert(!skb->consumed); skb->consumed++;
        if (current_device && skb==current_device->pm.tx_q[0].skb) observed.pm_skb_frees++;
    }
}
static void skb_get(struct sk_buff *skb) { assert(skb->references); skb->references++; }
static int skb_get_queue_mapping(struct sk_buff *skb) { (void)skb; return 0; }
static void skb_pull(struct sk_buff *skb, unsigned size) { assert(size<=sizeof(skb->storage)); skb->data+=size; skb->len-=size; }
static bool skb_queue_empty(struct sk_buff_head *queue) { return queue->head==NULL; }
static struct sk_buff *skb_dequeue(struct sk_buff_head *queue)
{
    struct sk_buff *skb=queue->head; if (skb) queue->head=skb->next; return skb;
}
#define __skb_dequeue(queue) skb_dequeue(queue)
static void skb_queue_purge(struct sk_buff_head *queue)
{
    struct sk_buff *skb; while ((skb=skb_dequeue(queue))) dev_kfree_skb(skb);
}
static void ieee80211_stop_queues(struct ieee80211_hw *hw) { (void)hw; observed.stops++; }
static void ieee80211_wake_queues(struct ieee80211_hw *hw) { (void)hw; observed.wakes++; }
static void ieee80211_scan_completed(struct ieee80211_hw *hw, const struct cfg80211_scan_info *info) { (void)hw; observed.scan_aborts+=info->aborted; }
static void ieee80211_sched_scan_results(struct ieee80211_hw *hw) { (void)hw; }
static void ieee80211_remain_on_channel_expired(struct ieee80211_hw *hw) { (void)hw; }
static void ieee80211_iterate_active_interfaces(struct ieee80211_hw *hw, int flags, void *callback, void *data)
{
    (void)hw;(void)flags;(void)callback;(void)data; observed.interfaces++; gate(G_ITERATE);
}
static void ieee80211_queue_delayed_work(struct ieee80211_hw *hw, struct delayed_work *work, int delay)
{
    (void)hw; queue_delayed_work(&queue_ordered,work,delay);
}
static void ieee80211_queue_work(struct ieee80211_hw *hw, struct work_struct *work) { (void)hw; queue_work(&queue_ordered,work); }
static void mt76_tx(struct mt76_phy *phy, struct ieee80211_sta *sta, struct mt76_wcid *wcid, struct sk_buff *skb) { (void)phy;(void)sta;(void)wcid; dev_kfree_skb(skb); }
static void mt76_txq_schedule_all(struct mt76_phy *phy) { (void)phy; }
static void mt76_update_survey(struct mt76_phy *phy) { (void)phy; }
static void mt792x_mac_update_mib_stats(struct mt792x_phy *phy) { (void)phy; }
static void mt76_tx_status_check(struct mt76_dev *dev, bool flush) { (void)dev;(void)flush; }
static void mt76_connac_tx_cleanup(struct mt76_dev *dev) { (void)dev; }
static int mt76_dma_rx_poll(struct napi_struct *napi, int budget)
{
    (void)budget; napi_complete(napi); mt792x_rx_poll_complete(&current_device->mt76,MT_RXQ_MAIN); return 0;
}
static void mt76_set_irq_mask(struct mt76_dev *dev, u32 address, u32 clear, u32 set)
{
    (void)address; mutex_lock(&dev->mmio.irq_lock); dev->mmio.irqmask=(dev->mmio.irqmask & ~clear)|set; mutex_unlock(&dev->mmio.irq_lock);
}
static void mt76_wr(struct mt792x_dev *dev, u32 address, u32 value) { (void)dev;(void)address;(void)value; }
static u32 mt76_rr(struct mt792x_dev *dev, u32 address) { (void)dev;(void)address; return 0; }
#define mt76_clear(...) do {} while (0)
#define mt76_set(...) do {} while (0)
#define mt76_poll(...) true
#define mt76_poll_msec_tick(...) true
static void mt76_connac2_tx_token_put(struct mt76_dev *dev) { (void)dev; observed.tokens=0; }
#define idr_init(token) (*(token)=0)
static int mt76_connac2_mcu_fill_message(struct mt76_dev *dev, struct sk_buff *skb, int cmd, int *seq) { (void)dev;(void)skb;(void)cmd; *seq=1; return 0; }
static int mt76_tx_queue_skb_raw(struct mt792x_dev *dev, struct mt76_queue *queue, struct sk_buff *skb, int flags)
{
    (void)queue;(void)flags; observed.mcu_enqueues++; observed.runtime_commands++;
    if (test_bit(MT76_STATE_RECOVERY_FAILED,&dev->mphy.state)) observed.runtime_commands_after_failed++;
    dev_kfree_skb(skb);
    if (!hold_response) dev->mt76.mcu.res_q.head=fixture_skb();
    announce(); return 0;
}
static int runtime_command(struct mt792x_dev *dev)
{
    return mt76_mcu_skb_send_and_get_msg(&dev->mt76,fixture_skb(),1,false,NULL);
}
static int mt76_connac_mcu_set_mac_enable(struct mt76_dev *dev, int band, bool enable, bool control)
{
    (void)band;(void)control;
    if (enable && observed.failure_stage==STAGE_START) return -EIO;
    return runtime_command(container_of(dev,struct mt792x_dev,mt76));
}
static int mt76_connac_mcu_set_channel_domain(struct mt76_phy *phy) { return runtime_command(container_of(phy->dev,struct mt792x_dev,mt76)); }
static int mt7921_mcu_set_chan_info(struct mt792x_phy *phy, int cmd) { (void)cmd; return runtime_command(phy->dev); }
static int mt7921_set_tx_sar_pwr(struct ieee80211_hw *hw, void *data) { (void)data; return runtime_command(mt792x_hw_dev(hw)); }
static void mt792x_mac_reset_counters(struct mt792x_phy *phy) { (void)phy; }
static int mt7921_mcu_radio_led_ctrl(struct mt792x_dev *dev, int command) { if (command==EXT_CMD_RADIO_OFF_LED && observed.led_error) return observed.led_error; return runtime_command(dev); }
static int mt7921_mcu_wf_rf_pin_ctrl(struct mt792x_phy *phy, int cmd) { (void)cmd; observed.rfkill_commands++; return runtime_command(phy->dev); }
static void wiphy_rfkill_set_hw_state(struct wiphy *wiphy, bool blocked) { (void)wiphy;(void)blocked; }
static void rfkill_set_block(struct rfkill *rfkill, bool blocked) { (void)rfkill;(void)blocked; }
static int mt792xe_mcu_drv_pmctrl(struct mt792x_dev *dev) { (void)dev; observed.ownership_calls++; return observed.ownership_error; }
static int mt792xe_mcu_fw_pmctrl(struct mt792x_dev *dev) { (void)dev; return observed.probe_failure==PROBE_FW_OWN ? -EIO : 0; }
static int __mt792xe_mcu_drv_pmctrl(struct mt792x_dev *dev) { (void)dev; observed.ownership_calls++; return observed.probe_failure==PROBE_DRV_OWN ? -EIO : observed.ownership_error; }
static int mt792x_wpdma_reset(struct mt792x_dev *dev, bool force)
{
    (void)dev;(void)force; observed.wpdma_calls++; observed.wfsys_calls++; observed.attempts++;
    if (observed.failure_stage==STAGE_WPDMA) return -EIO;
    if (!observed.failure_stage && observed.attempts!=observed.success_at) return -EIO;
    return 0;
}
static int mt7921e_driver_own(struct mt792x_dev *dev) { (void)dev; return observed.failure_stage==STAGE_DRIVER_OWN ? -EIO : 0; }
static int mt7921_run_firmware(struct mt792x_dev *dev) { (void)dev; return observed.failure_stage==STAGE_FIRMWARE ? -EIO : 0; }
static int mt7921_mcu_set_eeprom(struct mt792x_dev *dev) { (void)dev; return observed.failure_stage==STAGE_EEPROM ? -EIO : 0; }
static int mt7921_mac_init(struct mt792x_dev *dev) { (void)dev; return observed.failure_stage==STAGE_MAC_INIT ? -EIO : 0; }
static int mt792x_wfsys_reset(struct mt792x_dev *dev) { (void)dev; observed.wfsys_calls++; return observed.probe_failure==PROBE_WFSYS ? -EIO : 0; }
#define mt792x_wpdma_reinit_cond(dev) do {} while (0)
#define mt7921_roc_abort_sync(dev) do {} while (0)
#define mt7921_regd_update(dev) do {} while (0)
#define mt76_connac_mcu_set_deep_sleep(...) do {} while (0)
#define mt76_connac_mcu_set_hif_suspend(...) 0
#define mt76_mcu_skb_send_msg(dev, skb, cmd, wait) mt76_mcu_skb_send_and_get_msg(dev,skb,cmd,wait,NULL)
static void *vzalloc(size_t bytes) { return calloc(1,bytes); }
static void dev_coredumpv(struct device *dev, void *data, size_t size, int flags) { (void)dev;(void)size;(void)flags; free(data); }
static bool mtk_wed_device_active(int *wed) { (void)wed; return false; }
static bool mt76_queue_is_wed_rro(struct mt76_queue *queue) { (void)queue; return false; }
static void mtk_wed_device_detach(int *wed) { (void)wed; }
static void mt76_dma_tx_cleanup(struct mt76_dev *dev, struct mt76_queue *queue, bool force) { (void)dev;(void)force; if (queue) { assert(!queue->freed); queue->freed=true; observed.rings++; } }
static void mt76_dma_rx_cleanup(struct mt76_dev *dev, struct mt76_queue *queue) { (void)dev; assert(!queue->freed); queue->freed=true; observed.rings++; }
static void page_pool_destroy(void *page) { assert(page); observed.pages++; }
static void mt76_free_pending_txwi(struct mt76_dev *dev) { (void)dev; observed.txwi_frees++; }
static void mt76_free_pending_rxwi(struct mt76_dev *dev) { (void)dev; observed.rxwi_frees++; }
static void free_netdev(void *device) { (void)device; }
static void mt76_unregister_device(struct mt76_dev *dev)
{
    (void)dev;
    if (!cleanup_joined || current_device->rfkill_work.pending || current_device->rfkill_work.running) { observed.free_before_rfkill_join++; abort(); }
    assert(!fixture_rfkill.poll_work.work.pending && !fixture_rfkill.poll_work.work.running);
    fixture_rfkill.registered=false;
}
static void mt76_free_device(struct mt76_dev *dev)
{
    (void)dev; assert(!current_device->rfkill_work.pending && !current_device->rfkill_work.running);
    device_freed=true; observed.device_frees++;
}
/* Probe/device construction and register data are leaves, while the full probe
 * control flow and its actual INIT_WORK/flush error exits execute unchanged.
 */
#define mt7921e_tx_prepare_skb NULL
#define mt76_connac_tx_complete_skb NULL
#define mt7921_rx_check NULL
#define mt7921_queue_rx_skb NULL
#define mt7921_mac_sta_add NULL
#define mt7921_mac_sta_event NULL
#define mt7921_mac_sta_remove NULL
#define mt792x_update_channel NULL
#define mt7921_set_channel NULL
static int mt7921e_init_reset(struct mt792x_dev *dev) { (void)dev; return 0; }
static int mt7921e_mcu_init(struct mt792x_dev *dev) { (void)dev; return 0; }
static u32 mt7921_rr(struct mt76_dev *dev, u32 addr) { (void)dev;(void)addr; return 0; }
static void mt7921_wr(struct mt76_dev *dev, u32 addr, u32 value) { (void)dev;(void)addr;(void)value; }
static u32 mt7921_rmw(struct mt76_dev *dev, u32 addr, u32 clear, u32 set) { (void)dev;(void)addr;(void)clear; return set; }
static int pcim_enable_device(struct pci_dev *dev) { (void)dev; return 0; }
static int pcim_iomap_regions(struct pci_dev *dev, unsigned mask, const char *name) { (void)dev;(void)mask;(void)name; return 0; }
static const char *pci_name(struct pci_dev *dev) { (void)dev; return "fixture"; }
static void pci_read_config_word(struct pci_dev *dev, int reg, u16 *value) { (void)dev;(void)reg; *value=PCI_COMMAND_MEMORY; }
static void pci_write_config_word(struct pci_dev *dev, int reg, u16 value) { (void)dev;(void)reg;(void)value; }
static void pci_set_master(struct pci_dev *dev) { (void)dev; }
static int pci_alloc_irq_vectors(struct pci_dev *dev, int min, int max, int flags) { (void)dev;(void)min;(void)max;(void)flags; return 1; }
static int dma_set_mask(struct device *dev, u32 mask) { (void)dev;(void)mask; return 0; }
static void mt76_pci_disable_aspm(struct pci_dev *dev) { (void)dev; }
static bool mt76_pci_aspm_supported(struct pci_dev *dev) { (void)dev; return false; }
static struct ieee80211_ops *mt792x_get_mac80211_ops(struct device *dev, struct ieee80211_ops *ops, void *data, u8 *features) { (void)dev;(void)data; *features=0; return ops; }
static struct mt76_dev *mt76_alloc_device(struct device *dev, size_t size, struct ieee80211_ops *ops, const struct mt76_driver_ops *driver)
{
    (void)size;(void)ops;(void)driver; current_device->mt76.dev=dev; current_device->rfkill_work.initialized=false; return &current_device->mt76;
}
static void pci_set_drvdata(struct pci_dev *pdev, void *data) { pdev->data=data; }
static void **pcim_iomap_table(struct pci_dev *pdev) { (void)pdev; static void *map[1]; return map; }
static void mt76_mmio_init(struct mt76_dev *dev, void *map) { (void)map; dev->bus=&fixture_bus; }
static struct mt76_bus_ops *devm_kmemdup(struct device *dev, void *original, size_t size, int flags) { (void)dev;(void)size;(void)flags; return observed.probe_failure==PROBE_BUS_COPY ? NULL : original; }
static u32 mt7921_l1_rr(struct mt792x_dev *dev, u32 addr) { (void)dev; return addr==MT_HW_CHIPID ? 0x7922 : 0; }
static int devm_request_irq(struct device *dev, int irq, void *callback, int flags, const char *name, void *data) { (void)dev;(void)irq;(void)callback;(void)flags;(void)name;(void)data; return observed.probe_failure==PROBE_IRQ ? -EIO : 0; }
static int mt7921_dma_init(struct mt792x_dev *dev) { (void)dev; return observed.probe_failure==PROBE_DMA ? -EIO : 0; }
static int mt7921_register_device(struct mt792x_dev *dev) { (void)dev; return observed.probe_failure==PROBE_REGISTER ? -EIO : 0; }
static bool of_property_read_bool(void *node, const char *name) { (void)node;(void)name; return false; }
static void device_init_wakeup(struct device *dev, bool value) { (void)dev;(void)value; }
static void devm_free_irq(struct device *dev, int irq, void *data) { (void)dev;(void)irq;(void)data; }
static void pci_free_irq_vectors(struct pci_dev *dev) { (void)dev; }
#endif
