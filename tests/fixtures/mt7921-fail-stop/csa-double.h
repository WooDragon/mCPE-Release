/* CSA-only contracts for Linux 6.6.133 and package-patched backports 6.12.61.
 * Complete driver/core functions are generated from verified sources, not here.
 * Other radio, packet and BSS services are leaves; this is not a kernel test.
 */
#ifndef CSA_DOUBLE_H
#define CSA_DOUBLE_H
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

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef long ktime_t;
enum nl80211_band { NL80211_BAND_5GHZ };
struct ieee80211_channel { enum nl80211_band band; int center_freq; };
struct cfg80211_bss { struct ieee80211_channel *channel; unsigned char priv[16]; };
struct ieee80211_bss { int vht_cap_info; };
struct ieee802_11_elems { int csa_tpe; };
#define container_of(pointer, type, member) ((type *)((char *)(pointer) - offsetof(type, member)))
#define from_timer(variable, timer, member) container_of(timer, __typeof__(*variable), member)
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define READ_ONCE(value) fixture_read_once(&(value))
#define rcu_dereference(value) (value)
#define rcu_access_pointer(value) (value)
#define rcu_dereference_check(value, condition) (value)
#define sdata_dereference(value, sdata) (value)
#define WARN_ON(value) (!!(value))
#define WARN_ON_ONCE(value) WARN_ON(value)
#define EXPORT_SYMBOL(value)
#define EXPORT_SYMBOL_GPL(value)
#define TU_TO_EXP_TIME(value) ((unsigned long)(value) + 1)
#define __acquires(...)
#define __releases(...)
#define IEEE80211_IFACE_ITER_ACTIVE 1
#define IEEE80211_IFACE_ITER_RESUME_ALL 2
#define IEEE80211_IFACE_SKIP_SDATA_NOT_IN_DRIVER 4
#define IEEE80211_SDATA_IN_DRIVER 1
#define MONITOR_FLAG_ACTIVE 1
#define NL80211_IFTYPE_STATION 2
#define NL80211_IFTYPE_AP 3
#define NL80211_IFTYPE_MONITOR 4
#define NL80211_IFTYPE_AP_VLAN 5
#define IEEE80211_CHAN_DISABLED 1
#define IEEE80211_DEAUTH_FRAME_LEN 26
#define IEEE80211_STYPE_DEAUTH 1
#define WLAN_REASON_DEAUTH_LEAVING 2
#define WLAN_REASON_DISASSOC_DUE_TO_INACTIVITY 3
#define IEEE80211_CONF_PS 1
#define IEEE80211_CONF_CHANGE_PS 1
#define IEEE80211_SMPS_OFF 0
#define IEEE80211_UNSET_POWER_LEVEL -1
#define IEEE80211_REG_UNSET_AP 0
#define IEEE80211_SN_MODULO 4096
#define BSS_CHANGED_ASSOC 1
#define BSS_CHANGED_MU_GROUPS 2
#define BSS_CHANGED_ARP_FILTER 4
#define BSS_CHANGED_QOS 8
#define BSS_CHANGED_BSSID 16
#define BSS_CHANGED_HT 32
#define ASSOC_TIMEOUT 1
#define IS_ENABLED(option) 0
#define HZ 100

struct mutex { pthread_mutex_t lock; atomic_int owner; const char *name; };
struct work_struct { atomic_bool initialized, queued, running; atomic_int owner; };
struct delayed_work { struct work_struct work; };
struct timer_list { atomic_bool initialized, queued, running; atomic_int owner; unsigned long expires; };
struct wiphy_work { atomic_bool queued; };
struct wiphy_delayed_work { struct wiphy_work work; };
struct wiphy_hrtimer_work { struct wiphy_work work; };
struct mt792x_dev;
struct ieee80211_local;
struct ieee80211_sub_if_data;
struct wiphy { struct mutex mtx; };
struct cfg80211_chan_def { int identity; bool usable; struct ieee80211_channel *chan; };
struct ieee80211_chan_req { struct cfg80211_chan_def oper, ap; };
struct ieee80211_csa_ie { struct ieee80211_chan_req chanreq; bool mode; unsigned count, max_switch_time; };
struct ieee80211_chanctx;
struct mt792x_chanctx { void *bss_conf; };
struct ieee80211_chanctx_conf { struct cfg80211_chan_def def; _Alignas(struct mt792x_chanctx) unsigned char drv_priv[sizeof(struct mt792x_chanctx)]; };
struct ieee80211_hw { struct wiphy *wiphy; struct mt792x_dev *priv; struct { unsigned flags; } conf; };
struct mt76_phy { atomic_ulong state; struct ieee80211_hw *hw; struct delayed_work mac_work; };
struct mt76_dev { struct mt76_phy phy; struct mutex mutex; unsigned chip, bus; };
struct mt76_connac_pm { struct work_struct wake_work; struct delayed_work ps_work; };
struct mt792x_phy {
    struct mt792x_dev *dev; struct mt76_phy *mt76;
    struct delayed_work scan_work; struct timer_list roc_timer;
    struct work_struct roc_work; int scan_event_list;
};
struct mt792x_bss_conf { struct { struct ieee80211_chanctx_conf *ctx; } mt76; };
struct mt792x_vif {
    struct mt792x_phy *phy; struct mt792x_bss_conf bss_conf;
    struct { int deflink; } sta;
    struct work_struct csa_work; struct timer_list csa_timer;
};
struct ieee80211_bss_conf {
    atomic_bool csa_active; u16 beacon_int; struct cfg80211_bss *bss;
    struct ieee80211_chan_req chanreq; struct ieee80211_chanctx_conf *chanctx_conf;
    int p2p_noa_attr;
    struct { u8 membership[8], position[8]; } mu_group;
    bool mu_mimo_owner, qos; int arp_addr_cnt, dtim_period; void *beacon_rate;
    int power_type, pwr_reduction, tpe;
};
struct ieee80211_vif {
    int type; u8 addr[6]; unsigned valid_links, active_links;
    struct { atomic_bool assoc; u8 ap_addr[6]; int ssid_len, arp_addr_cnt;
             int eml_cap, eml_med_sync_delay, mld_capa_op; } cfg;
    struct ieee80211_bss_conf bss_conf; int neg_ttlm;
    _Alignas(struct mt792x_vif) unsigned char drv_priv[sizeof(struct mt792x_vif)];
};
struct ieee80211_channel_switch {
    struct cfg80211_chan_def chandef; unsigned count, delay, link_id;
    u64 timestamp; u32 device_timestamp; bool block_tx;
};
struct ieee80211_chanctx { struct ieee80211_chanctx_conf conf; int mode; };
struct ieee80211_if_managed {
    bool associated, driver_disconnect, reconnect; void *assoc_data, *auth_data;
    struct wiphy_work csa_connection_drop_work, monitor_work, beacon_connection_loss_work, teardown_ttlm_work;
    struct wiphy_delayed_work tdls_peer_del_work, tx_tspec_wk, ttlm_work, neg_ttlm_timeout_work, ml_reconf_work;
    struct mutex teardown_lock; void *teardown_skb, *orig_teardown_skb, *assoc_req_ies;
    int assoc_req_ies_len, ht_capa, ht_capa_mask, vht_capa, vht_capa_mask, flags;
    int tx_tspec[4], ttlm_info, removed_links, mcast_seq_last;
    struct timer_list timer, conn_mon_timer, bcn_mon_timer;
};
struct ieee80211_link_data {
    struct ieee80211_sub_if_data *sdata; struct ieee80211_bss_conf *conf;
    int smps_mode, ap_power_level; unsigned link_id;
    struct { struct ieee80211_chan_req chanreq; } csa;
    union { struct {
        int conn; bool beacon_crc_valid;
        struct { bool blocked_tx, waiting_bcn, ignored_same_chan;
                 struct wiphy_hrtimer_work switch_work; int tpe;
                 ktime_t time; struct cfg80211_chan_def ap_chandef; } csa;
        struct wiphy_work request_smps_work, recalc_smps;
        u8 bssid[6]; int p2p_noa_index;
        bool have_beacon, tracking_signal_avg, disable_wmm_tracking;
    } mgd; } u;
};
struct ieee80211_ops {
    void (*remove_interface)(struct ieee80211_hw *, struct ieee80211_vif *);
    int (*add_interface)(struct ieee80211_hw *, struct ieee80211_vif *);
    void (*channel_switch)(struct ieee80211_hw *, struct ieee80211_vif *, struct ieee80211_channel_switch *);
};
struct ieee80211_sub_if_data {
    struct ieee80211_local *local; struct ieee80211_vif vif; unsigned flags;
    struct ieee80211_sub_if_data *list; void *dev;
    union { struct ieee80211_if_managed mgd; struct { unsigned flags; } mntr; } u;
    struct ieee80211_link_data deflink, *link[1];
};
struct ieee80211_local {
    struct ieee80211_hw hw; struct mutex iflist_mtx;
    struct ieee80211_sub_if_data *interfaces, *monitor_sdata, *ps_sdata;
    struct ieee80211_ops *ops;
    struct timer_list dynamic_ps_timer; struct wiphy_work dynamic_ps_enable_work;
};
struct mt792x_dev {
    union { struct mt76_dev mt76; struct mt76_phy mphy; }; struct mt792x_phy phy;
    struct mt76_connac_pm pm; struct ieee80211_chanctx_conf *new_ctx;
    struct { struct delayed_work work; int msg_list; } coredump;
    struct work_struct ipv6_ns_work; int ipv6_ns_list;
};
struct ieee80211_prep_tx_info { int subtype; bool was_assoc; int link_id; };
#define list_for_each_entry_rcu(sdata, head, member, ...) for ((sdata)=*(head); (sdata); (sdata)=(sdata)->member)
#define hw_to_local(hw) container_of(hw, struct ieee80211_local, hw)
#define vif_to_sdata(vif) container_of(vif, struct ieee80211_sub_if_data, vif)
#define mt792x_hw_dev(hw) ((hw)->priv)
#define mt76_hw(dev) ((dev)->mphy.hw)
#define mt76_chip(dev) ((dev)->chip)
#define mt792x_mutex_acquire(dev) mt76_connac_mutex_acquire(&(dev)->mt76, &(dev)->pm)
#define mt792x_mutex_release(dev) mt76_connac_mutex_release(&(dev)->mt76, &(dev)->pm)
#define mt792x_link_conf_to_mconf(conf) (&((struct mt792x_vif *)container_of(conf, struct ieee80211_vif, bss_conf)->drv_priv)->bss_conf)
#define ieee80211_sdata_running(sdata) true
#define CHANCTX_STA_CSA 1
#define NO_VIRTUAL_MONITOR 2
#define WANT_MONITOR_VIF 3
#define ieee80211_hw_check(hw, flag) ((flag) == CHANCTX_STA_CSA)
#define rcu_dereference_protected(value, condition) (value)
#define unlikely(value) (value)
#define link_info(...) do {} while (0)
#define ieee80211_chswitch_post_beacon(...) do {} while (0)
#define ieee80211_sta_abort_chanswitch(...) do {} while (0)
#define ieee80211_sta_other_link_csa_disappeared(...) do {} while (0)
#define ieee80211_teardown_tdls_peers(...) do {} while (0)
#define ieee80211_set_chanreq_ap(...) do {} while (0)
#define ieee80211_link_reserve_chanctx(...) 0
#define cfg80211_ch_switch_started_notify(...) do {} while (0)
#define ktime_get_boottime() 0
#define max_t(type, first, second) ((first) > (second) ? (first) : (second))
#define ns_to_ktime(value) (value)
#define ieee80211_tu_to_usec(value) ((value) * 1024)
#define NSEC_PER_USEC 1000
#define trace_drv_add_interface(...) do {} while (0)
#define trace_drv_return_int(...) do {} while (0)
#define drv_vif_add_debugfs(...) do {} while (0)
#define ieee80211_link_debugfs_drv_add(...) do {} while (0)
#define trace_drv_remove_interface(...)
#define trace_drv_return_void(...)
#define trace_api_chswitch_done(...) fixture_notification()
#define sdata_info(...)
#define ieee80211_debugfs_recreate_netdev(...) do {} while (0)
#define might_sleep() fixture_might_sleep()
#define lockdep_is_held(lock) fixture_owned(lock)
#define check_sdata_in_driver(sdata) ((sdata)->flags & IEEE80211_SDATA_IN_DRIVER)
#define lockdep_assert_wiphy(wiphy) assert(fixture_owned(&(wiphy)->mtx))
#define tracepoint(...)

/* Exact core association/CSA cleanup is executed; unrelated BSS/radio leaves. */
#define ieee80211_stop_poll(...) do {} while (0)
#define netif_carrier_off(...) do {} while (0)
#define ieee80211_hw_config(...) do {} while (0)
#define ieee80211_recalc_ps_vif(...) do {} while (0)
#define ieee80211_flush_queues(...) do {} while (0)
#define drv_mgd_prepare_tx(...) do {} while (0)
#define ieee80211_send_deauth_disassoc(...) do {} while (0)
#define drv_mgd_complete_tx(...) do {} while (0)
#define eth_zero_addr(address) memset(address, 0, 6)
#define sta_info_flush(...)
#define ieee80211_vif_is_mld(...) false
#define ieee80211_reset_erp_info(...) 0
#define ieee80211_led_assoc(...)
#define ieee80211_bss_info_change_notify(...)
#define ieee80211_vif_cfg_change_notify(...)
#define ieee80211_set_wmm_default(...)
#define ieee80211_clear_tpe(...)
#define ieee80211_vif_set_links(...) 0
#define ieee80211_destroy_assoc_data(...) do {} while (0)
#define ieee80211_destroy_auth_data(...) do {} while (0)
#define spin_lock_bh(lock) mutex_lock(lock)
#define spin_unlock_bh(lock) mutex_unlock(lock)
#define kfree_skb(pointer) free(pointer)
#define kfree(pointer) free(pointer)
#define cfg80211_unlink_bss(...)
#define ieee80211_report_disconnect(...) fixture_report_disconnect()
#define ieee80211_vif_link_active(vif, link_id) true
#define skb_queue_purge(...)
#define mt76_connac_free_pending_tx_skbs(...)
#define ieee80211_remain_on_channel_expired(...) do {} while (0)

/* Gate points represent separate original API operations, never atomic pairs. */
enum gate_point { G_NONE, G_TIMER_CANCEL, G_WORK_RUNNING, G_TIMER_RUNNING,
    G_ADD, G_MOD, G_QUEUE, G_DEAD_CHECK, G_MCU, G_READ_ACTIVE, G_CORE_QUEUE,
    G_MUTEX_WAIT, G_CORE_PRODUCE };
struct fixture {
    struct mt792x_dev dev; struct ieee80211_local local; struct wiphy wiphy;
    struct ieee80211_sub_if_data sdata; struct ieee80211_chanctx_conf context;
    struct ieee80211_ops ops; struct ieee80211_channel channel; struct cfg80211_bss bss;
    struct ieee80211_chanctx core_context;
    int mcu_result;
    atomic_int faults, mcu, pm_wakes, pm_releases, removals, notifications, disconnects;
    atomic_int timer_joins, work_joins, core_queues, sequence, timer_order, work_order, remove_order;
    atomic_int rcu_readers, grace_waits, sync_waits;
    atomic_bool destroyed; unsigned long clock;
    atomic_int pre_calls, callbacks_finished;
};
extern struct fixture *current;
extern _Thread_local unsigned rcu_depth;
void fixture_init(struct fixture *fixture);
void fixture_gate(enum gate_point point);
void fixture_arm_gate(enum gate_point point);
void fixture_wait_gate(void);
void fixture_release_gate(void);
void fixture_wait_counter(atomic_int *counter, int value);
void fixture_might_sleep(void);
bool fixture_owned(struct mutex *lock);
void mutex_lock(struct mutex *lock);
void mutex_unlock(struct mutex *lock);
void rcu_read_lock(void);
void rcu_read_unlock(void);
void synchronize_rcu(void);
void synchronize_net(void);
bool fixture_read_once(const atomic_bool *value);
bool test_bit(unsigned bit, const atomic_ulong *state);
void set_bit(unsigned bit, atomic_ulong *state);
bool test_and_clear_bit(unsigned bit, atomic_ulong *state);
void fixture_end_running(atomic_bool *running);
void fixture_begin_running(atomic_bool *running, atomic_int *owner);
void fixture_mark_destroyed(void);
void fixture_notification(void);
void fixture_report_disconnect(void);
void add_timer(struct timer_list *timer);
void mod_timer(struct timer_list *timer, unsigned long expires);
void del_timer_sync(struct timer_list *timer);
void cancel_work_sync(struct work_struct *work);
void cancel_work(struct work_struct *work);
void cancel_delayed_work(struct delayed_work *work);
void cancel_delayed_work_sync(struct delayed_work *work);
void ieee80211_queue_work(struct ieee80211_hw *hw, struct work_struct *work);
void wiphy_work_queue(struct wiphy *wiphy, struct wiphy_work *work);
void wiphy_work_cancel(struct wiphy *wiphy, struct wiphy_work *work);
void wiphy_hrtimer_work_queue(struct wiphy *wiphy, struct wiphy_hrtimer_work *work, unsigned long delay);
void wiphy_hrtimer_work_cancel(struct wiphy *wiphy, struct wiphy_hrtimer_work *work);
void wiphy_delayed_work_cancel(struct wiphy *wiphy, struct wiphy_delayed_work *work);
int mt76_connac_pm_wake(struct mt76_phy *phy, struct mt76_connac_pm *pm);
void mt76_connac_power_save_sched(struct mt76_phy *phy, struct mt76_connac_pm *pm);
int mt76_connac_mcu_uni_set_chctx(struct mt76_phy *phy, void *conf, struct ieee80211_chanctx_conf *context);
void mt792x_mac_link_bss_remove(struct mt792x_dev *dev, struct mt792x_bss_conf *conf, int *sta);
void ieee80211_link_release_channel(struct ieee80211_link_data *link);
void ieee80211_vif_unblock_queues_csa(struct ieee80211_sub_if_data *sdata);
bool cfg80211_chandef_usable(struct wiphy *wiphy, struct cfg80211_chan_def *def, unsigned flags);
bool cfg80211_chandef_identical(struct cfg80211_chan_def *first, struct cfg80211_chan_def *second);
int ieee80211_parse_ch_switch_ie(struct ieee80211_sub_if_data *sdata, struct ieee802_11_elems *elements,
    enum nl80211_band band, int capabilities, void *connection, u8 *address, bool unprotected,
    struct ieee80211_csa_ie *result);
int drv_pre_channel_switch(struct ieee80211_sub_if_data *sdata, struct ieee80211_channel_switch *request);
void drv_channel_switch(struct ieee80211_local *local, struct ieee80211_sub_if_data *sdata,
                        struct ieee80211_channel_switch *request);
void drv_channel_switch_rx_beacon(struct ieee80211_sub_if_data *sdata, struct ieee80211_channel_switch *request);
void ieee80211_vif_block_queues_csa(struct ieee80211_sub_if_data *sdata);
#endif
