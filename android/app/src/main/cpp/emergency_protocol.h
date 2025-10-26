#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif

#define MAX_PAYLOAD 256
#define DEVICE_ID_LEN 32
#define MSG_TYPE_LEN 16
#define EVENT_BUF_MAX 1024
#define NEIGHBOR_MAX 256
#define DEDUPE_WINDOW_SECONDS 300 // 5 dakika

    typedef struct
    {
        uint8_t version;
        char device_id[DEVICE_ID_LEN]; // null-terminated if shorter
        char message_type[MSG_TYPE_LEN];
        uint8_t payload[MAX_PAYLOAD];
        uint32_t payload_len;
        uint32_t timestamp; // epoch seconds
        uint8_t ttl;
    } emergency_packet_t;

    /*
     * Simple API:
     * - init: başlat
     * - send_broadcast: uygulama katmanından gönder (sadece queue'ya ekler)
     * - receive_raw: radio/stack'ten gelen ham veriyi ver (parse, dedupe, neighbor update)
     * - poll_incoming: gelen application-level paketlerin raw serileştirilmiş bytesini döner
     * - get_neighbors_json: neighbors listesini JSON olarak döner (buffer'a yaz)
     */

    void emergency_protocol_init(const char *self_device_id);
    int emergency_send_broadcast(const char *message); // message is raw text; returns 0 ok
    int emergency_receive_raw(const uint8_t *raw, uint32_t raw_len, int rssi, const char *remote_addr);
    int emergency_poll_incoming(uint8_t *out_buf, uint32_t max_len);    // returns bytes written or 0 if none
    int emergency_get_neighbors_json(char *out_json, uint32_t max_len); // returns bytes written or -1 on error

#ifdef __cplusplus
}
#endif
