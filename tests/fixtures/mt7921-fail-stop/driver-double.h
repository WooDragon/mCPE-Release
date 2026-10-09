/* User-space API model for complete mt76 functions. Not a kernel/DMA test.
 * Base APIs: Linux 6.6.133; wireless framework: package-patched backports 6.12.61.
 * CSA owns its separate existing model. Hardware/packet/allocation leaves below
 * are deliberately not modeled as complete firmware or PCI implementations.
 */
#ifndef DRIVER_DOUBLE_H
#define DRIVER_DOUBLE_H
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint32_t __le32;
typedef uint16_t __le16;
#define __packed __attribute__((packed))
#define struct_group_tagged(tag, name, ...) __VA_ARGS__
typedef int irqreturn_t;
#define container_of(pointer, type, member) ((type *)((char *)(pointer) - offsetof(type, member)))
#define from_timer(variable, timer, member) container_of(timer, __typeof__(*variable), member)
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define BIT(bit) (1u << (bit))
#define __acquires(...)
#define __releases(...)
#define EXPORT_SYMBOL_GPL(...)
#define EXPORT_SYMBOL(...)
#define IS_ENABLED(option) 1
#define unlikely(value) (value)
#define READ_ONCE(value) (value)
#define HZ 100
#define IEEE80211_NUM_ACS 4
#define IEEE80211_IFACE_ITER_RESUME_ALL 1
#define MT792x_WATCHDOG_TIME 100
#define MT792x_CHIP_CAP_WF_RF_PIN_CTRL_EVT_EN 1
#define MT76_CONNAC_COREDUMP_TIMEOUT 100
#define MT76_CONNAC_COREDUMP_SZ 256
#define GFP_KERNEL 0
#define IRQ_NONE 0
#define IRQ_HANDLED 1
#define IRQF_SHARED 1
#define KBUILD_MODNAME "mt7921e-model"
#define IRQ_TYPE 1
#define MT_TXD_SIZE 16
#define MT7921_TOKEN_SIZE 16
#define MT_DRV_TXWI_NO_FREE 1
#define MT_DRV_HW_MGMT_TXQ 2
#define MT_DRV_AMSDU_OFFLOAD 4
#define SURVEY_INFO_TIME_TX 1
#define SURVEY_INFO_TIME_RX 2
#define SURVEY_INFO_TIME_BSS_RX 4
#define PCI_COMMAND 1
#define PCI_COMMAND_MEMORY 2
#define PCI_IRQ_ALL_TYPES 1
#define DMA_BIT_MASK(bits) UINT32_MAX
#define MT_WFDMA0_HOST_INT_ENA 1
#define MT_WFDMA0_HOST_INT_STA 2
#define MT_PCIE_MAC_INT_ENABLE 3
#define MT_MCU_CMD 4
#define MT_MCU2HOST_SW_INT_ENA 5
#define MT_WFDMA0_GLO_CFG 6
#define MT_WFDMA0_RST 7
#define MT_HW_CHIPID 8
#define MT_HW_BOUND 9
#define MT_HW_REV 10
#define MT_INT_TX_DONE_ALL 1
#define MT_INT_TX_DONE_MCU 2
#define MT_INT_RX_DONE_DATA 4
#define MT_INT_RX_DONE_WM 8
#define MT_INT_RX_DONE_WM2 16
#define MT_INT_RX_DONE_ALL 28
#define MT_INT_MCU_CMD 32
#define MT_MCU_CMD_WAKE_RX_PCIE 64
#define MT_WFDMA0_GLO_CFG_TX_DMA_EN 1
#define MT_WFDMA0_GLO_CFG_RX_DMA_EN 2
#define MT_WFDMA0_GLO_CFG_CSR_DISP_BASE_PTR_CHAIN_EN 4
#define MT_WFDMA0_GLO_CFG_OMIT_TX_INFO 8
#define MT_WFDMA0_GLO_CFG_OMIT_RX_INFO 16
#define MT_WFDMA0_GLO_CFG_OMIT_RX_INFO_PFET2 32
#define MT_WFDMA0_GLO_CFG_TX_DMA_BUSY 64
#define MT_WFDMA0_GLO_CFG_RX_DMA_BUSY 128
#define MT_WFDMA0_RST_DMASHDL_ALL_RST 1
#define MT_WFDMA0_RST_LOGIC_RST 2
#define WF_RF_PIN_INIT 1
#define WF_RF_PIN_POLL 2
#define EXT_CMD_RADIO_OFF_LED 1
#define EXT_CMD_RADIO_ON_LED 2
#define EXT_CMD_RADIO_LED_CTRL_ENABLE 3
#define __MCU_CMD_FIELD_ID 255
#define FIELD_GET(mask, value) ((value) & (mask))
#define FW_SCATTER 10
#define PATCH_SEM_CONTROL 11
#define PATCH_FINISH_REQ 12
#define THERMAL_CTRL 13
#define DEV_INFO_UPDATE 14
#define BSS_INFO_UPDATE 15
#define STA_REC_UPDATE 16
#define HIF_CTRL 17
#define OFFLOAD 18
#define SUSPEND 19
#define REG_READ 20
#define WF_RF_PIN_CTRL 21
#define SET_RX_PATH 22
#define MCU_EVENT_SCHED_SCAN_DONE 23
#define MCU_CMD(value) (value)
#define MCU_EXT_CMD(value) ((value) + 256)
#define MCU_UNI_CMD(value) ((value) + 512)
#define MCU_CE_QUERY(value) ((value) + 768)
#define le32_to_cpu(value) (value)
#define POLL_INTERVAL 500
#define RFKILL_BLOCK_SW 1
#define round_jiffies_relative(value) (value)
#define BUG_ON(value) assert(!(value))
#define WARN_ON(value) (!!(value))
#define barrier() atomic_thread_fence(memory_order_seq_cst)
#define trace_drv_stop(...)
#define trace_drv_return_void(...)
#define trace_rdev_rfkill_poll(...)
#define trace_rdev_return_void(...)
#define trace_dev_irq(...)
#define might_sleep() do {} while (0)
#define dev_dbg(...) do {} while (0)
#define dev_info(...) do {} while (0)
#define dev_err(...) do { observed.logs++; } while (0)

struct mutex { pthread_mutex_t real; atomic_int owner; const char *name; };
struct work_struct {
    atomic_bool initialized, pending, running; atomic_int owner;
    void (*callback)(struct work_struct *); const char *name;
};
struct delayed_work { struct work_struct work; };
struct timer_list { atomic_bool pending; };
struct tasklet_struct { atomic_bool pending, running; int disabled; };
struct mt76_worker { bool parked; };
struct device { void *of_node; };
struct pci_dev { struct device dev; int irq; void *data; };
struct pci_device_id { uintptr_t driver_data; };
struct sk_buff { int consumed, references, len; u8 storage[128], *data; struct sk_buff *next; };
struct sk_buff_head { struct sk_buff *head; };
struct napi_struct { atomic_bool enabled, sched, running, deleted; void *dev; int disables, enables; };
struct mt76_queue { bool freed; void *page_pool; };
struct mt76_wcid { bool sta; };
struct ieee80211_sta { u8 drv_priv[16]; };
struct ieee80211_vif;
struct mt76_phy;
struct mt76_dev;
struct mt792x_dev;
struct rfkill;
struct ieee80211_local;
struct rfkill_ops { void (*poll)(struct rfkill *, void *); };
struct rfkill {
    struct device dev; struct delayed_work poll_work; struct rfkill_ops *ops; void *data;
    bool polling_paused, suspended, registered, persistent; unsigned state;
};
struct wiphy { struct mutex mtx; struct rfkill *rfkill; struct ieee80211_local *local; };
struct cfg80211_ops { void (*rfkill_poll)(struct wiphy *); };
struct cfg80211_registered_device { struct wiphy wiphy; struct cfg80211_ops *ops; struct rfkill_ops rfkill_ops; };
struct ieee80211_hw { void *priv; struct wiphy *wiphy; };
struct ieee80211_ops { void (*stop)(struct ieee80211_hw *, bool); void (*rfkill_poll)(struct ieee80211_hw *); };
struct ieee80211_local { struct ieee80211_hw hw; struct ieee80211_ops *ops; bool started; struct tasklet_struct tasklet; };
struct cfg80211_wowlan { int unused; };
struct cfg80211_scan_info { bool aborted; };
enum mt76_rxq_id { MT_RXQ_MAIN, MT_RXQ_MCU, MT_RXQ_MCU_WA };
enum mt76_mcuq_id { MT_MCUQ_WM, MT_MCUQ_FWDL };
struct mt76_phy {
    atomic_ulong state; struct ieee80211_hw *hw; struct mt76_dev *dev; void *priv;
    struct delayed_work mac_work; int mac_work_count; struct mt76_queue *q_tx[2];
};
struct mt76_bus_ops { u32 (*rr)(struct mt76_dev *, u32); void (*wr)(struct mt76_dev *, u32, u32); u32 (*rmw)(struct mt76_dev *, u32, u32, u32); };
struct mt76_mcu_ops {
    int(*mcu_skb_prepare_msg)(struct mt76_dev *, struct sk_buff *, int, int *);
    int(*mcu_skb_send_msg)(struct mt76_dev *, struct sk_buff *, int, int *);
    int(*mcu_parse_response)(struct mt76_dev *, int, struct sk_buff *, int);
    unsigned max_retry;
};
struct mt76_dev {
    struct mt76_phy phy; struct mutex mutex, lock; struct device *dev; void *wq;
    struct mt76_bus_ops *bus; unsigned rev; int bus_kind; atomic_int bus_hung;
    struct { struct mt76_worker txrx_worker; } sdio;
    struct { struct mutex mutex; int wait; unsigned long timeout; struct sk_buff_head res_q; } mcu;
    struct mt76_mcu_ops *mcu_ops;
    struct { struct mutex irq_lock; unsigned irqmask; int wed, wed_hif2; } mmio;
    struct napi_struct napi[3], tx_napi; struct tasklet_struct irq_tasklet;
    struct mt76_worker tx_worker; int token;
    struct mt76_phy *phys[2]; struct mt76_queue q_rx[3], *q_mcu[2];
    void *napi_dev, *tx_napi_dev;
};
struct mt76_connac_pm {
    struct mutex mutex, txq_lock; struct { struct mutex lock; int count; } wake;
    struct { struct mt76_wcid *wcid; struct sk_buff *skb; } tx_q[4];
    struct delayed_work ps_work; struct work_struct wake_work;
    bool enable, suspended, ds_enable; int wait; unsigned long last_activity, idle_timeout;
};
struct mt792x_phy {
    struct mt76_phy *mt76; struct mt792x_dev *dev; unsigned chip_cap;
    struct delayed_work scan_work; struct timer_list roc_timer; struct work_struct roc_work;
    struct sk_buff_head scan_event_list; int roc_wait;
};
struct mt792x_hif_ops {
    int(*init_reset)(struct mt792x_dev *), (*reset)(struct mt792x_dev *);
    void (*reset_failed)(struct mt792x_dev *);
    int(*mcu_init)(struct mt792x_dev *), (*drv_own)(struct mt792x_dev *), (*fw_own)(struct mt792x_dev *);
};
struct mt792x_irq_map { u32 host_irq_enable; struct { u32 all_complete_mask, mcu_complete_mask; } tx; struct { u32 data_complete_mask, wm_complete_mask, wm2_complete_mask; } rx; };
struct mt792x_dev {
    union { struct mt76_dev mt76; struct mt76_phy mphy; }; struct mt792x_phy phy;
    struct mt76_connac_pm pm; struct work_struct reset_work, rfkill_work, init_work;
    struct delayed_work unused; struct { struct delayed_work work; struct sk_buff_head msg_list; unsigned long last_activity; } coredump;
    struct work_struct ipv6_ns_work; struct sk_buff_head ipv6_ns_list;
    struct mt792x_hif_ops const *hif_ops; struct mt792x_irq_map const *irq_map;
    struct mt76_bus_ops *bus_ops; bool hw_full_reset, hw_init_done, fw_assert, aspm_supported, regd_in_progress;
    unsigned fw_features; int wait;
};
#include "driver-packet.h"
struct mt7921_wf_rf_pin_ctrl_event { u8 result; };
struct mt76_connac_hw_txp { u8 unused[8]; };
struct mt76_driver_ops {
    unsigned txwi_size, drv_flags, survey_flags, token_size;
    void *tx_prepare_skb, *tx_complete_skb, *rx_check, *rx_skb, *rx_poll_complete;
    void *sta_add, *sta_event, *sta_remove, *update_survey, *set_channel;
};
enum { STAGE_WPDMA = 1, STAGE_DRIVER_OWN, STAGE_FIRMWARE, STAGE_EEPROM, STAGE_MAC_INIT, STAGE_START };
enum { PROBE_FIRST_DEVICE_ERROR = 1, PROBE_BUS_COPY = 1, PROBE_FW_OWN, PROBE_DRV_OWN, PROBE_WFSYS, PROBE_IRQ, PROBE_DMA, PROBE_REGISTER, PROBE_LAST_DEVICE_ERROR = PROBE_REGISTER };
enum { REMOVE_BEFORE_LAST_QUEUE, REMOVE_QUEUED_CLEANUP, REMOVE_RUNNING_CLEANUP };
static struct {
    atomic_int attempts, success_at, ownership_error, wakes, stops, interfaces, scan_aborts;
    atomic_int ps_schedules, napi_schedules, resets, waiter_wakes, logs, failure_stage;
    atomic_int mcu_enqueues, runtime_commands, runtime_commands_after_failed, tx_napi_schedules;
    atomic_int parks, unparks, locked_waits, wpdma_calls, after_failed_irq_enables, irq_schedule_outside_lock;
    atomic_int rfkill_commands, rfkill_work_queues, rfkill_work_wrong_queue, reset_joins_rfkill, stop_joins_rfkill;
    atomic_int callback_after_free, flush_before_producer_join, free_before_rfkill_join, probe_failure;
    atomic_int join_uninitialized_work, device_frees, led_error, pm_skb_frees, reset_sync_cancels;
    atomic_int ownership_calls, wfsys_calls, napi_deletes, rings, pages, txwi_frees, rxwi_frees, tokens, cleanup_stops;
} observed;
static struct mt792x_dev *current_device;
static struct ieee80211_local fixture_local;
static struct cfg80211_registered_device fixture_rdev;
static struct rfkill fixture_rfkill;
static struct pci_dev fixture_pci;
static struct mt76_bus_ops fixture_bus;
static struct mt76_queue fixture_tx[2], fixture_mcu[2];
static int queue_ordered, queue_unbound, queue_power;
#define system_unbound_wq (&queue_unbound)
#define system_power_efficient_wq (&queue_power)
#define mt76_hw(dev) ((dev)->mphy.hw)
#define mt792x_hw_phy(hw) ((struct mt792x_phy *)((struct mt76_phy *)(hw)->priv)->priv)
#define mt792x_hw_dev(hw) (mt792x_hw_phy(hw)->dev)
#define mt76_is_sdio(dev) ((dev)->bus_kind == 2)
#define mt76_is_usb(dev) ((dev)->bus_kind == 1)
#define mt76_is_mmio(dev) ((dev)->bus_kind == 0)
#define mt76_chip(dev) ((dev)->rev >> 16)
#define mt76_priv(dev) (dev)
#define mt76_for_each_q_rx(dev, index) for ((index)=0; (index)<3; (index)++)
#define mt792x_mutex_acquire(dev) mt76_connac_mutex_acquire(&(dev)->mt76, &(dev)->pm)
#define mt792x_mutex_release(dev) mt76_connac_mutex_release(&(dev)->mt76, &(dev)->pm)
#define mt76_connac_skip_fw_pmctrl(phy, pm) false
#define wiphy_priv(wiphy) ((wiphy)->local)
#define wiphy_to_rdev(wiphy) container_of(wiphy, struct cfg80211_registered_device, wiphy)
#define to_rfkill(pointer) container_of(pointer, struct rfkill, dev)
#define to_pci_dev(pointer) container_of(pointer, struct pci_dev, dev)
#define pci_get_drvdata(pdev) ((pdev)->data)
#define local_bh_disable() do {} while (0)
#define local_bh_enable() do {} while (0)
#define jiffies 100ul
#define time_is_after_jiffies(value) ((value) > jiffies)
#define time_is_before_jiffies(value) ((value) < jiffies)
#define atomic_read(value) atomic_load(value)
#define mt7921_vif_connect_iter ((void *)1)
#define mt7921_mcu_set_suspend_iter ((void *)2)
#define mt76_connac_mcu_set_suspend_iter ((void *)3)
#define mt7921_roc_iter ((void *)4)
#include "driver-sync.h"
#endif
