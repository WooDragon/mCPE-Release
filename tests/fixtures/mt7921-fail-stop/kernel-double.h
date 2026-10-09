/* Kernel API boundaries for the real extracted functions. Not a second driver. */
#ifndef MT7921_KERNEL_DOUBLE_H
#define MT7921_KERNEL_DOUBLE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>

#define container_of(pointer, type, member) ((type *)((char *)(pointer) - offsetof(type, member)))
#define EXPORT_SYMBOL_GPL(symbol)
#define HZ 100
#define IEEE80211_IFACE_ITER_RESUME_ALL 0
#define MT792x_WATCHDOG_TIME 100
#define unlikely(value) (value)
typedef uint8_t u8;
struct work_struct { bool pending, running; const char *name; };
struct delayed_work { struct work_struct work; };
struct mutex { bool held; };
struct ieee80211_hw { void *priv; };
struct cfg80211_scan_info { bool aborted; };
struct mt76_phy {
    unsigned long state;
    struct ieee80211_hw *hw;
    struct mt76_dev *dev;
    struct delayed_work mac_work;
};
struct mt76_dev {
    struct mt76_phy phy;
    struct mutex mutex;
    void *dev, *wq;
    int bus_hung, bus;
    struct { void *txrx_worker; } sdio;
    void *napi[3];
};
struct mt76_connac_pm {
    struct delayed_work ps_work;
    struct work_struct wake_work;
    bool suspended;
    int wait;
};
struct mt792x_phy { struct mt76_phy *mt76; };
struct mt792x_dev {
    union { struct mt76_dev mt76; struct mt76_phy mphy; };
    struct mt792x_phy phy;
    struct mt76_connac_pm pm;
    struct work_struct reset_work;
    bool hw_full_reset;
};
static struct {
    int attempts, success_at, ownership_error;
    int wakes, stops, interfaces, scan_aborts, ps_schedules;
    int napi_schedules, resets, waiter_wakes, wait_calls, logs;
} observed;
#define mt76_hw(dev) ((dev)->mphy.hw)
#define mt76_is_sdio(dev) ((dev)->bus == 2)
#define atomic_read(value) (*(value))
static bool test_bit(int bit, const unsigned long *state) { return !!(*state & (1ul << bit)); }
static void set_bit(int bit, unsigned long *state) { *state |= 1ul << bit; }
static void clear_bit(int bit, unsigned long *state) { *state &= ~(1ul << bit); }
static bool test_and_clear_bit(int bit, unsigned long *state)
{
    bool result = test_bit(bit, state);
    clear_bit(bit, state);
    return result;
}
static void mutex_lock(struct mutex *lock) { if (lock->held) abort(); lock->held = true; }
static void mutex_unlock(struct mutex *lock) { if (!lock->held) abort(); lock->held = false; }
static void cancel_delayed_work_sync(struct delayed_work *work) { if (work->work.running) abort(); work->work.pending = false; }
static void cancel_work_sync(struct work_struct *work) { if (work->running) abort(); work->pending = false; }
static bool queue_work(void *queue, struct work_struct *work) { (void)queue; work->pending = true; observed.resets++; return true; }
static void ieee80211_stop_queues(struct ieee80211_hw *hw) { (void)hw; observed.stops++; }
static void ieee80211_wake_queues(struct ieee80211_hw *hw) { (void)hw; observed.wakes++; }
static void ieee80211_scan_completed(struct ieee80211_hw *hw, const struct cfg80211_scan_info *info)
{ (void)hw; if (info->aborted) observed.scan_aborts++; }
static void mt7921_vif_connect_iter(void *priv, u8 *mac, void *vif)
{ (void)priv; (void)mac; (void)vif; }
static void ieee80211_iterate_active_interfaces(struct ieee80211_hw *hw, int flags, void *callback, void *priv)
{ (void)hw; (void)flags; (void)callback; (void)priv; observed.interfaces++; }
static void mt76_connac_power_save_sched(struct mt76_phy *phy, struct mt76_connac_pm *pm)
{ (void)phy; (void)pm; observed.ps_schedules++; }
static int mt792x_dev_reset(struct mt792x_dev *dev)
{ (void)dev; return ++observed.attempts == observed.success_at ? 0 : -EIO; }
static int mt792x_mcu_drv_pmctrl(struct mt792x_dev *dev)
{ (void)dev; return observed.ownership_error; }
static void mt76_connac_pm_dequeue_skbs(struct mt76_phy *phy, struct mt76_connac_pm *pm) { (void)phy; (void)pm; }
static void mt76_connac_tx_cleanup(struct mt76_dev *dev) { (void)dev; }
static void mt76_worker_schedule(void *worker) { (void)worker; }
static void local_bh_disable(void) {}
static void local_bh_enable(void) {}
static void napi_schedule(void *napi) { (void)napi; observed.napi_schedules++; }
static void ieee80211_queue_delayed_work(struct ieee80211_hw *hw, struct delayed_work *work, int delay)
{ (void)hw; (void)delay; work->work.pending = true; }
static void wake_up(int *wait) { (void)wait; observed.waiter_wakes++; }
#define mt76_for_each_q_rx(dev, index) for ((index) = 0; (index) < 0; (index)++)
#define dev_dbg(device, ...) ((void)(device))
#define dev_err(device, ...) do { (void)(device); observed.logs++; } while (0)
#endif
