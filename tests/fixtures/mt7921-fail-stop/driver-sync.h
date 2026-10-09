/* Blocking primitives: callbacks are real pthreads, not canceled by fiat.
 * NAPI SCHED and running C function lifetime are deliberately separate.
 */
#ifndef DRIVER_SYNC_H
#define DRIVER_SYNC_H
static pthread_mutex_t events = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static atomic_int next_identity, callbacks_finished;
static int finished_at_arm;
static _Thread_local int identity;
static struct mutex *waiting[32];
static int joining[32];
static _Thread_local int role;
enum { ROLE_MAIN, ROLE_RESET, ROLE_STOP, ROLE_POLL, ROLE_CLEANUP, ROLE_REMOVE, ROLE_PM, ROLE_MCU, ROLE_IRQ, ROLE_NAPI_SERVICE };
enum gate { G_NONE, G_LAST_ATTEMPT, G_ITERATE, G_NAPI_TAIL, G_IRQ_CHECK, G_BEFORE_RFQUEUE };
static int armed_gate, arrived_gate;
static bool gate_released;
static atomic_bool hold_response, device_freed, producer_joined, cleanup_joined;
/* Test controller can hold dispatch without pretending queued NAPI completed. */
static bool hold_napi_dispatch, napi_sync_waiting, napi_sync_done;
static atomic_int napi_poll_calls;
static int mt792x_poll_tx(struct napi_struct *napi, int budget);
static int mt792x_poll_rx(struct napi_struct *napi, int budget);
static struct sk_buff *sender_request;
static int sender_result;

static int thread_identity(void)
{
    if (!identity) identity = atomic_fetch_add(&next_identity, 1) + 1;
    assert(identity < 32);
    return identity;
}
static void announce(void)
{
    pthread_mutex_lock(&events);
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events);
}
static void check_wait_graph(void)
{
    for (int start = 1; start <= atomic_load(&next_identity); start++) {
        int cursor = start;
        for (int hops = 0; hops < 32; hops++) {
            cursor = waiting[cursor] ? atomic_load(&waiting[cursor]->owner) : joining[cursor];
            if (!cursor) break;
            if (cursor == start) {
                fprintf(stderr, "CONTRACT: lock/work/controller wait cycle\n");
                abort();
            }
        }
    }
}
static void gate(enum gate point)
{
    pthread_mutex_lock(&events);
    if (armed_gate == point && !gate_released) {
        arrived_gate = point;
        joining[thread_identity()] = 1;
        check_wait_graph();
        pthread_cond_broadcast(&changed);
        while (!gate_released) pthread_cond_wait(&changed, &events);
        joining[thread_identity()] = 0;
    }
    pthread_mutex_unlock(&events);
}
static void arm_gate(enum gate point)
{
    pthread_mutex_lock(&events);
    armed_gate = point; arrived_gate = G_NONE; gate_released = false;
    finished_at_arm = callbacks_finished;
    pthread_mutex_unlock(&events);
}
static void wait_gate(enum gate point)
{
    pthread_mutex_lock(&events);
    while (arrived_gate != point && callbacks_finished == finished_at_arm)
        pthread_cond_wait(&changed, &events);
    if (arrived_gate != point) {
        fprintf(stderr, "CONTRACT: callback completed without required gate %d\n", point);
        abort();
    }
    pthread_mutex_unlock(&events);
}
static void release_gate(void)
{
    pthread_mutex_lock(&events);
    gate_released = true;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events);
}
static void mutex_init(struct mutex *lock, const char *name)
{
    pthread_mutex_init(&lock->real, NULL); atomic_init(&lock->owner, 0); lock->name = name;
}
static void mutex_lock(struct mutex *lock)
{
    int self = thread_identity();
    pthread_mutex_lock(&events);
    waiting[self] = lock;
    check_wait_graph(); pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&events);
    pthread_mutex_lock(&lock->real);
    pthread_mutex_lock(&events);
    waiting[self] = NULL; atomic_store(&lock->owner, self);
    pthread_cond_broadcast(&changed); pthread_mutex_unlock(&events);
}
static void mutex_unlock(struct mutex *lock)
{
    assert(atomic_load(&lock->owner) == thread_identity());
    atomic_store(&lock->owner, 0); pthread_mutex_unlock(&lock->real); announce();
    /* The real tenth HIF operation has released mt76 before .stop can enter
     * its reset join. This hook changes no driver function or HIF routing. */
    if (role==ROLE_RESET && current_device && lock==&current_device->mt76.mutex && observed.attempts==10)
        gate(G_LAST_ATTEMPT);
}
static bool mutex_is_locked(struct mutex *lock) { return atomic_load(&lock->owner) != 0; }
static bool owned(struct mutex *lock) { return atomic_load(&lock->owner) == thread_identity(); }
#define spin_lock_bh(lock) mutex_lock(lock)
#define spin_unlock_bh(lock) mutex_unlock(lock)
#define spin_lock_irqsave(lock, flags) do { (flags)=0; mutex_lock(lock); } while (0)
#define spin_unlock_irqrestore(lock, flags) do { (void)(flags); mutex_unlock(lock); } while (0)
#define lockdep_assert_wiphy(wiphy) assert(owned(&(wiphy)->mtx))
#define wiphy_lock(wiphy) mutex_lock(&(wiphy)->mtx)
#define wiphy_unlock(wiphy) mutex_unlock(&(wiphy)->mtx)
static bool test_bit(int bit, const atomic_ulong *state)
{
    bool value = !!(atomic_load(state) & (1ul << bit));
    if (bit == MT76_STATE_RECOVERY_FAILED && current_device &&
        state == &current_device->mphy.state && owned(&current_device->mt76.mmio.irq_lock) && !value && role == ROLE_IRQ)
        gate(G_IRQ_CHECK);
    return value;
}
static void set_bit(int bit, atomic_ulong *state) { atomic_fetch_or(state, 1ul << bit); announce(); }
static void clear_bit(int bit, atomic_ulong *state) { atomic_fetch_and(state, ~(1ul << bit)); announce(); }
static bool test_and_set_bit(int bit, atomic_ulong *state) { bool old=!!(atomic_fetch_or(state,1ul<<bit)&(1ul<<bit)); announce(); return old; }
static bool test_and_clear_bit(int bit, atomic_ulong *state) { bool old=!!(atomic_fetch_and(state,~(1ul<<bit))&(1ul<<bit)); announce(); return old; }
static void work_init(struct work_struct *work, void (*callback)(struct work_struct *), const char *name)
{
    memset(work, 0, sizeof(*work)); work->initialized=true; work->callback=callback; work->name=name;
}
#define INIT_WORK(work, callback) work_init(work, callback, #work)
static void no_locked_wait(void)
{
    if (current_device && (owned(&current_device->mt76.mutex) || owned(&current_device->mt76.mcu.mutex) || owned(&current_device->pm.mutex) || owned(&current_device->mt76.mmio.irq_lock))) {
        observed.locked_waits++; fprintf(stderr, "CONTRACT: blocking wait holds driver lock\n"); abort();
    }
}
static void work_begin(struct work_struct *work)
{
    pthread_mutex_lock(&events);
    assert(work->initialized && !work->running);
    work->pending=false; work->owner=thread_identity(); work->running=true;
    pthread_cond_broadcast(&changed); pthread_mutex_unlock(&events);
}
static void work_end(struct work_struct *work)
{
    pthread_mutex_lock(&events);
    work->running=false; work->owner=0; callbacks_finished++;
    pthread_cond_broadcast(&changed); pthread_mutex_unlock(&events);
}
static void *run_work(void *pointer)
{
    struct work_struct *work=pointer;
    role=current_device && work==&current_device->rfkill_work ? ROLE_CLEANUP : ROLE_POLL;
    work_begin(work); work->callback(work); work_end(work); return NULL;
}
static bool cancel_work_sync(struct work_struct *work)
{
    if (work->running) no_locked_wait();
    if (!work->initialized) { observed.join_uninitialized_work++; abort(); }
    if (current_device && work==&current_device->rfkill_work) {
        if (role==ROLE_RESET) observed.reset_joins_rfkill++;
        if (role==ROLE_STOP) observed.stop_joins_rfkill++;
    }
    if (work==&fixture_rfkill.poll_work.work && role==ROLE_CLEANUP) observed.cleanup_stops++;
    if (current_device && work==&current_device->reset_work) observed.reset_sync_cancels++;
    bool pending=atomic_exchange(&work->pending,false);
    pthread_mutex_lock(&events);
    while (work->running) {
        joining[thread_identity()]=work->owner; check_wait_graph();
        pthread_cond_broadcast(&changed); pthread_cond_wait(&changed,&events);
    }
    joining[thread_identity()]=0;
    /* cancel synchronously suppresses a running callback's final self-requeue. */
    work->pending=false; pthread_mutex_unlock(&events);
    if (current_device && work==&current_device->init_work) { producer_joined=false; cleanup_joined=false; }
    if (current_device && work==&current_device->reset_work) { producer_joined=true; announce(); }
    return pending;
}
static bool cancel_work(struct work_struct *work) { return atomic_exchange(&work->pending,false); }
static bool cancel_delayed_work(struct delayed_work *work) { return cancel_work(&work->work); }
static bool cancel_delayed_work_sync(struct delayed_work *work) { return cancel_work_sync(&work->work); }
static bool queue_work(void *queue, struct work_struct *work)
{
    assert(work->initialized);
    if (device_freed) { observed.callback_after_free++; abort(); }
    if (current_device && work==&current_device->rfkill_work) {
        gate(G_BEFORE_RFQUEUE); observed.rfkill_work_queues++;
        observed.rfkill_work_wrong_queue += queue!=system_unbound_wq;
    }
    if (current_device && work==&current_device->reset_work) observed.resets++;
    return !atomic_exchange(&work->pending,true);
}
static bool queue_delayed_work(void *queue, struct delayed_work *work, unsigned long delay)
{
    (void)delay;
    if (current_device && work==&current_device->pm.ps_work) observed.ps_schedules++;
    return queue_work(queue,&work->work);
}
static bool flush_work(struct work_struct *work)
{
    no_locked_wait(); assert(work->initialized);
    if (current_device && work==&current_device->rfkill_work) {
        if (role==ROLE_RESET) observed.reset_joins_rfkill++;
        if (role==ROLE_STOP) observed.stop_joins_rfkill++;
        if (role==ROLE_REMOVE && !producer_joined) observed.flush_before_producer_join++;
    }
    pthread_t worker; bool started=false;
    pthread_mutex_lock(&events);
    if (work->pending && !work->running) { assert(work->callback); pthread_create(&worker,NULL,run_work,work); started=true; }
    while (work->running || (started && work->pending)) {
        joining[thread_identity()]=work->owner; check_wait_graph();
        pthread_cond_wait(&changed,&events);
    }
    joining[thread_identity()]=0; pthread_mutex_unlock(&events);
    if (started) pthread_join(worker,NULL);
    if (current_device && work==&current_device->rfkill_work) { cleanup_joined=true; announce(); }
    return started;
}
static void wake_up(int *wait) { (void)wait; observed.waiter_wakes++; announce(); }
#define wait_event_timeout(wait, condition, timeout) ({ \
    (void)(wait); (void)(timeout); long result=0; \
    pthread_mutex_lock(&events); \
    while (!(condition)) { \
        if (!hold_response) break; \
        pthread_cond_broadcast(&changed); pthread_cond_wait(&changed,&events); \
    } \
    result=!!(condition); pthread_mutex_unlock(&events); result; })
static void napi_schedule(struct napi_struct *napi) { assert(napi->enabled); napi->sched=true; observed.napi_schedules++; if (napi==&current_device->mt76.tx_napi) observed.tx_napi_schedules++; }
static bool napi_complete(struct napi_struct *napi) { bool old=atomic_exchange(&napi->sched,false); announce(); if (role==ROLE_POLL) gate(G_NAPI_TAIL); return old; }
/* Linux 6.6.133 netdevice.h:558-565: SMP waits on SCHED, not C lifetime.
 * This bounded executor services queued polls on demand. Only the extracted
 * poll may complete SCHED; the controller may hold dispatch to prove waiting.
 */
static void napi_synchronize(struct napi_struct *napi)
{
    no_locked_wait(); pthread_mutex_lock(&events);
    while (napi->sched) {
        napi_sync_waiting=true; pthread_cond_broadcast(&changed);
        if (napi->running || hold_napi_dispatch) {
            pthread_cond_wait(&changed,&events);
            continue;
        }
        napi->running=true;
        pthread_mutex_unlock(&events);
        /* The held C tail belongs to the explicitly started poll, not
         * unrelated queued polls encountered by later reset attempts. */
        int saved_role=role; role=ROLE_NAPI_SERVICE; napi_poll_calls++;
        if (napi==&current_device->mt76.tx_napi) mt792x_poll_tx(napi,64);
        else mt792x_poll_rx(napi,64);
        role=saved_role;
        pthread_mutex_lock(&events);
        napi->running=false; pthread_cond_broadcast(&changed);
    }
    pthread_mutex_unlock(&events);
}
static void napi_disable(struct napi_struct *napi)
{
    no_locked_wait(); assert(napi->enabled); napi_synchronize(napi);
    napi->enabled=false; napi->disables++;
}
static void napi_enable(struct napi_struct *napi) { assert(!napi->enabled && !napi->deleted); napi->enabled=true; napi->enables++; }
static void netif_napi_del(struct napi_struct *napi) { assert(!napi->enabled && !napi->deleted); napi->deleted=true; observed.napi_deletes++; }
static void tasklet_schedule(struct tasklet_struct *tasklet)
{
    assert(!tasklet->disabled); tasklet->pending=true;
    if (tasklet==&current_device->mt76.irq_tasklet && role==ROLE_IRQ && !owned(&current_device->mt76.mmio.irq_lock)) observed.irq_schedule_outside_lock++;
    if (tasklet==&current_device->mt76.irq_tasklet && test_bit(MT76_STATE_RECOVERY_FAILED,&current_device->mphy.state)) observed.after_failed_irq_enables++;
}
static void tasklet_kill(struct tasklet_struct *tasklet) { no_locked_wait(); assert(!tasklet->disabled && !tasklet->running); tasklet->pending=false; }
static void tasklet_disable(struct tasklet_struct *tasklet) { tasklet->disabled++; }
static void tasklet_enable(struct tasklet_struct *tasklet) { assert(tasklet->disabled); tasklet->disabled--; }
static void tasklet_init(struct tasklet_struct *tasklet, void *callback, unsigned long data) { (void)callback;(void)data; memset(tasklet,0,sizeof(*tasklet)); }
static void synchronize_irq(int irq) { (void)irq; no_locked_wait(); }
static void del_timer_sync(struct timer_list *timer) { no_locked_wait(); timer->pending=false; }
static void mt76_worker_disable(struct mt76_worker *worker) { no_locked_wait(); assert(!worker->parked); worker->parked=true; observed.parks++; }
static void mt76_worker_enable(struct mt76_worker *worker) { assert(worker->parked); worker->parked=false; observed.unparks++; }
static void mt76_worker_schedule(struct mt76_worker *worker) { (void)worker; }
#endif
