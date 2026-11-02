/* Reply mailboxes for honk::ask. Goose's typed queues are one per type for
   the whole process, so a store thread answering several workers cannot
   address a reply through them. Each worker instead waits on a slot of its
   own here, keyed by its worker id. A slot holds one serialized reply and
   the sequence number of the call it answers, so a reply that comes after
   its asker gave up is dropped rather than read as the next answer. */
#include "goose.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
static SRWLOCK honk_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE honk_cond = CONDITION_VARIABLE_INIT;
#define honk_mail_lock() AcquireSRWLockExclusive(&honk_lock)
#define honk_mail_unlock() ReleaseSRWLockExclusive(&honk_lock)
#define honk_mail_wake() WakeAllConditionVariable(&honk_cond)
#else
#include <errno.h>
#include <pthread.h>
#include <time.h>
static pthread_mutex_t honk_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t honk_cond = PTHREAD_COND_INITIALIZER;
#define honk_mail_lock() pthread_mutex_lock(&honk_lock)
#define honk_mail_unlock() pthread_mutex_unlock(&honk_lock)
#define honk_mail_wake() pthread_cond_broadcast(&honk_cond)
#endif

typedef struct { const uint8_t *data; int64_t len; } honk_mail_bytes;   /* const u8[:] */

#define HONK_MAIL_SLOTS 256

typedef struct {
    uint8_t *data;
    int64_t len, cap;
    int64_t seq;            /* the call this reply answers */
    bool full;
} honk_slot;

static honk_slot honk_slots[HONK_MAIL_SLOTS];

int64_t honk_mail_slots(void) { return HONK_MAIL_SLOTS; }

/* Leaves a reply for the worker in slot, replacing any unread one. */
bool honk_mail_put(int64_t slot, int64_t seq, honk_mail_bytes reply) {
    if (slot < 0 || slot >= HONK_MAIL_SLOTS) return false;
    honk_mail_lock();
    honk_slot *s = &honk_slots[slot];
    if (s->cap < reply.len) {
        uint8_t *grown = (uint8_t *)realloc(s->data, (size_t)reply.len);
        if (!grown) { honk_mail_unlock(); return false; }
        s->data = grown;
        s->cap = reply.len;
    }
    if (reply.len > 0) memcpy(s->data, reply.data, (size_t)reply.len);
    s->len = reply.len;
    s->seq = seq;
    s->full = true;
    honk_mail_wake();
    honk_mail_unlock();
    return true;
}

/* Waits up to timeout_ms for the reply to call seq in slot, and appends it
   to out. Replies to earlier calls are dropped. */
bool honk_mail_take(int64_t slot, int64_t seq, gs_rref out, int64_t timeout_ms) {
    if (slot < 0 || slot >= HONK_MAIL_SLOTS) return false;
#ifndef _WIN32
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += (time_t)(timeout_ms / 1000);
    until.tv_nsec += (long)((timeout_ms % 1000) * 1000000);
    if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
#else
    ULONGLONG until = GetTickCount64() + (ULONGLONG)timeout_ms;
#endif
    honk_mail_lock();
    honk_slot *s = &honk_slots[slot];
    for (;;) {
        if (s->full && s->seq == seq) break;
        if (s->full) s->full = false;                 /* a stale reply */
#ifdef _WIN32
        ULONGLONG now = GetTickCount64();
        if (now >= until) { honk_mail_unlock(); return false; }
        SleepConditionVariableSRW(&honk_cond, &honk_lock, (DWORD)(until - now), 0);
#else
        int rc = pthread_cond_timedwait(&honk_cond, &honk_lock, &until);
        if (rc == ETIMEDOUT && !(s->full && s->seq == seq)) { honk_mail_unlock(); return false; }
#endif
    }
    gs_bld_append(out, s->data, s->len);
    s->full = false;
    honk_mail_unlock();
    return true;
}
