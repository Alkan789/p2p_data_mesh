// emergency_protocol.cpp
#include "emergency_protocol.h"
#include <string>
#include <vector>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <deque>
#include <ctime>
#include <cstring>
#include <sstream>
#include <iomanip>
#include <algorithm>

// For json simple creation (no external dep). We'll manual build JSON strings.
#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "emergency_protocol", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "emergency_protocol", __VA_ARGS__)
#else
#include <stdio.h>
#define LOGI(...)        \
    printf(__VA_ARGS__); \
    printf("\n")
#define LOGE(...)        \
    printf(__VA_ARGS__); \
    printf("\n")
#endif

using namespace std;

static std::mutex g_mutex;

// Configuration
static const size_t MAX_NEIGHBORS = NEIGHBOR_MAX;
static const uint32_t DEDUPE_WINDOW = DEDUPE_WINDOW_SECONDS; // seconds
static const size_t MAX_INCOMING_BUF = EVENT_BUF_MAX;
static const size_t MAX_DEVICE_ID = DEVICE_ID_LEN;

// Wire format (simple):
// [0..1] magic: 'E','P'
// [2] version (1)
// [3..6] msg_id (uint32_t, big endian)
// [7] frag_idx (uint8_t)
// [8] frag_count (uint8_t)
// [9] ttl (uint8_t)
// [10] devlen (uint8_t)
// [11..11+devlen-1] device_id (utf8, no null)
// [..] payload_len (uint16_t big endian) then payload bytes

struct IncomingPacket
{
    vector<uint8_t> data; // reconstructed payload (application-level)
    int rssi;
    string remote_addr;
    string device_id;
    uint32_t timestamp;
};

// neighbor struct
struct Neighbor
{
    string device_id;
    string address;
    int rssi;
    uint32_t last_seen; // epoch seconds
};

// For reassembly
struct ReassemblyEntry
{
    uint32_t msg_id;
    uint8_t frag_count;
    vector<vector<uint8_t>> frags;
    string device_id;
    int received_mask; // bitmask for received fragments (if frag_count <= 32)
    uint32_t first_seen;
};

static string g_self_device_id;
static unordered_map<string, Neighbor> g_neighbors;
static deque<IncomingPacket> g_incoming_queue;
static unordered_map<uint32_t, ReassemblyEntry> g_reassembly;
static unordered_map<uint32_t, uint32_t> g_msg_timestamps; // msg_id -> last seen seconds (for dedupe)
static unordered_set<uint32_t> g_recent_messages;          // quick dedupe
static uint32_t g_next_msg_id = 1;

// helper: read big-endian uint32/16
static uint32_t read_u32_be(const uint8_t *p)
{
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
static uint16_t read_u16_be(const uint8_t *p)
{
    return (uint16_t(p[0]) << 8) | uint16_t(p[1]);
}

// helper to current epoch seconds
static uint32_t now_s()
{
    return static_cast<uint32_t>(std::time(nullptr));
}

// garbage collect old reassembly entries and dedupe window
static void gc_cleanup()
{
    uint32_t now = now_s();
    // dedupe cleanup
    for (auto it = g_msg_timestamps.begin(); it != g_msg_timestamps.end();)
    {
        if (now - it->second > DEDUPE_WINDOW)
            it = g_msg_timestamps.erase(it);
        else
            ++it;
    }
    // reassembly cleanup older than DEDUPE_WINDOW
    for (auto it = g_reassembly.begin(); it != g_reassembly.end();)
    {
        if (now - it->second.first_seen > (DEDUPE_WINDOW))
            it = g_reassembly.erase(it);
        else
            ++it;
    }
    // incoming_queue limit
    while (g_incoming_queue.size() > 1024)
        g_incoming_queue.pop_front();
    // neighbor pruning
    for (auto it = g_neighbors.begin(); it != g_neighbors.end();)
    {
        if (now - it->second.last_seen > (DEDUPE_WINDOW * 2))
            it = g_neighbors.erase(it);
        else
            ++it;
    }
}

// parse a raw advertisement frame (manufacturer bytes)
static void parse_raw_frame_and_feed(const uint8_t *raw, uint32_t raw_len, int rssi, const char *remote_addr)
{
    if (raw_len < 12)
        return; // too small for header
    if (raw[0] != 'E' || raw[1] != 'P')
        return; // not our protocol
    uint8_t ver = raw[2];
    if (ver != 1)
        return; // only v1 supported
    uint32_t msg_id = read_u32_be(raw + 3);
    uint8_t frag_idx = raw[7];
    uint8_t frag_count = raw[8];
    uint8_t ttl = raw[9];
    uint8_t devlen = raw[10];
    size_t idx = 11;
    if (idx + devlen + 2 > raw_len)
        return; // need payload_len
    string device_id;
    if (devlen > 0)
    {
        device_id.assign((const char *)(raw + idx), devlen);
    }
    idx += devlen;
    if (idx + 2 > raw_len)
        return;
    uint16_t payload_len = read_u16_be(raw + idx);
    idx += 2;
    if (idx + payload_len > raw_len)
        return;
    const uint8_t *payload_ptr = raw + idx;

    std::lock_guard<std::mutex> lock(g_mutex);
    // dedupe quick test: if msg_id seen recently and frag_count==1, skip
    if (g_msg_timestamps.find(msg_id) != g_msg_timestamps.end())
    {
        // we may still be receiving fragments for an existing reassembly; continue
    }

    // find or create reassembly entry
    auto it = g_reassembly.find(msg_id);
    if (it == g_reassembly.end())
    {
        ReassemblyEntry e;
        e.msg_id = msg_id;
        e.frag_count = frag_count;
        e.frags.assign(fragerCountMax(frag_count), vector<uint8_t>()); // helper below
        e.received_mask = 0;
        e.first_seen = now_s();
        e.device_id = device_id;
        g_reassembly[msg_id] = std::move(e);
        it = g_reassembly.find(msg_id);
    }
    ReassemblyEntry &entry = it->second;
    if (frag_idx >= entry.frags.size())
    {
        // sanity
        return;
    }
    // store fragment
    entry.frags[frag_idx] = vector<uint8_t>(payload_ptr, payload_ptr + payload_len);
    entry.received_mask |= (1 << frag_idx);
    // update neighbor with device id if provided
    if (!device_id.empty())
    {
        auto nit = g_neighbors.find(device_id);
        uint32_t t = now_s();
        if (nit == g_neighbors.end())
        {
            Neighbor n;
            n.device_id = device_id;
            n.address = remote_addr ? string(remote_addr) : string("");
            n.rssi = rssi;
            n.last_seen = t;
            if (g_neighbors.size() < MAX_NEIGHBORS)
                g_neighbors[device_id] = std::move(n);
        }
        else
        {
            nit->second.rssi = rssi;
            nit->second.last_seen = t;
            if (!nit->second.address.empty() && nit->second.address != string(remote_addr))
                nit->second.address = string(remote_addr);
        }
    }

    // check reassembly complete
    bool complete = true;
    for (uint8_t i = 0; i < entry.frag_count; ++i)
    {
        if (((entry.received_mask >> i) & 1) == 0)
        {
            complete = false;
            break;
        }
    }
    if (complete)
    {
        // join payloads
        vector<uint8_t> full;
        for (uint8_t i = 0; i < entry.frag_count; ++i)
        {
            auto &f = entry.frags[i];
            full.insert(full.end(), f.begin(), f.end());
        }
        // dedupe based on msg_id & timestamp
        uint32_t now = now_s();
        auto dIt = g_msg_timestamps.find(msg_id);
        if (dIt == g_msg_timestamps.end() || now - dIt->second > DEDUPE_WINDOW)
        {
            g_msg_timestamps[msg_id] = now;
            // push to incoming queue
            IncomingPacket ip;
            ip.data = std::move(full);
            ip.rssi = rssi;
            ip.remote_addr = remote_addr ? string(remote_addr) : string("");
            ip.device_id = entry.device_id;
            ip.timestamp = now;
            g_incoming_queue.push_back(std::move(ip));
            // cap queue size
            while (g_incoming_queue.size() > MAX_INCOMING_BUF)
                g_incoming_queue.pop_front();
        }
        // cleanup reassembly entry
        g_reassembly.erase(msg_id);
    }

    // cleanup periodically
    gc_cleanup();
}

// helper to allocate vector size for fragments (to avoid variable sized ctor)
static size_t fragerCountMax(uint8_t frag_count)
{
    return (frag_count == 0 ? 1 : frag_count);
}

// Public API implementations:

#ifdef __cplusplus
extern "C"
{
#endif

    void emergency_protocol_init(const char *self_device_id)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (self_device_id)
            g_self_device_id = string(self_device_id);
        else
            g_self_device_id = "unknown";
        g_neighbors.clear();
        g_incoming_queue.clear();
        g_reassembly.clear();
        g_msg_timestamps.clear();
        g_recent_messages.clear();
        // initialize msg id generator seeded with time
        g_next_msg_id = static_cast<uint32_t>(std::time(nullptr)) & 0x7fffffff;
        LOGI("Emergency protocol initialized (self id: %s)", g_self_device_id.c_str());
    }

    int emergency_send_broadcast(const char *message)
    {
        if (!message)
            return -1;
        std::lock_guard<std::mutex> lock(g_mutex);

        // create a message id
        uint32_t msg_id = ++g_next_msg_id;
        uint8_t frag_max_payload = 20; // safe payload for BLE adv after headers (tune as needed)
        vector<uint8_t> payload_vec;
        const char *p = message;
        size_t len = strlen(p);
        payload_vec.insert(payload_vec.end(), p, p + len);

        // build fragments
        uint8_t frag_count = (payload_vec.size() + frag_max_payload - 1) / frag_max_payload;
        if (frag_count == 0)
            frag_count = 1;

        // for each fragment, create a wire frame (header + chunk) and push to outgoing queue
        // NOTE: currently we only put them into incoming queue (loopback) so scan on same device can see them
        // In real deployment, you should hand fragments to advertising component so others receive them.
        for (uint8_t i = 0; i < frag_count; ++i)
        {
            size_t start = size_t(i) * frag_max_payload;
            size_t chunk_len = std::min<size_t>(frag_max_payload, payload_vec.size() - start);
            vector<uint8_t> frame;
            // header
            frame.push_back('E');
            frame.push_back('P');
            frame.push_back(1); // version
            // msg_id big endian
            frame.push_back((msg_id >> 24) & 0xFF);
            frame.push_back((msg_id >> 16) & 0xFF);
            frame.push_back((msg_id >> 8) & 0xFF);
            frame.push_back((msg_id >> 0) & 0xFF);
            frame.push_back(i);          // frag idx
            frame.push_back(frag_count); // frag count
            frame.push_back(4);          // ttl, small
            uint8_t devlen = (uint8_t)std::min<size_t>(g_self_device_id.size(), MAX_DEVICE_ID - 1);
            frame.push_back(devlen);
            for (size_t d = 0; d < devlen; ++d)
                frame.push_back((uint8_t)g_self_device_id[d]);
            // payload len (2 bytes BE)
            uint16_t chunk_len_u16 = (uint16_t)chunk_len;
            frame.push_back((chunk_len_u16 >> 8) & 0xFF);
            frame.push_back((chunk_len_u16 >> 0) & 0xFF);
            // payload
            frame.insert(frame.end(), payload_vec.begin() + start, payload_vec.begin() + start + chunk_len);

            // For simplicity we push the assembled frame into incoming queue (loopback) so local app can test;
            // In production: send frame via advertiser (platform).
            IncomingPacket ip;
            ip.data = std::move(frame);
            ip.rssi = 0;
            ip.remote_addr = "local";
            ip.device_id = g_self_device_id;
            ip.timestamp = now_s();
            g_incoming_queue.push_back(std::move(ip));
        }

        // Return 0 = OK
        LOGI("Queued broadcast msg_id=%u frag_count=%u", msg_id, frag_count);
        return 0;
    }

    // Provide an implementation where platform code will call this for every received raw manufacturer bytes
    int emergency_receive_raw(const uint8_t *raw, uint32_t raw_len, int rssi, const char *remote_addr)
    {
        if (!raw || raw_len == 0)
            return -1;
        // parse & feed into reassembly/incoming
        parse_raw_frame_and_feed(raw, raw_len, rssi, remote_addr);
        return 0;
    }

    // Pop next application-level outgoing (already reassembled) packet into out_buf
    int emergency_poll_incoming(uint8_t *out_buf, uint32_t max_len)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_incoming_queue.empty())
            return 0;
        IncomingPacket ip = std::move(g_incoming_queue.front());
        g_incoming_queue.pop_front();
        // we want to return the application payload as-is (we stored whole frame for the loopback case)
        // If the stored data is a full frame, we should extract payload; but here for simplicity if frame begins with 'E','P' parse to get payload
        if (ip.data.size() >= 12 && ip.data[0] == 'E' && ip.data[1] == 'P')
        {
            // parse header to get payload pos
            size_t idx = 11;
            uint8_t devlen = ip.data[10];
            idx += devlen;
            if (idx + 2 > ip.data.size())
                return 0;
            uint16_t payload_len = read_u16_be(ip.data.data() + idx);
            idx += 2;
            if (idx + payload_len > ip.data.size())
                return 0;
            if (payload_len > max_len)
                payload_len = max_len;
            memcpy(out_buf, ip.data.data() + idx, payload_len);
            return (int)payload_len;
        }
        else
        {
            // if not our frame, copy raw
            uint32_t copy_len = std::min<uint32_t>(max_len, (uint32_t)ip.data.size());
            memcpy(out_buf, ip.data.data(), copy_len);
            return (int)copy_len;
        }
    }

    // produce neighbors JSON into out_json buffer
    int emergency_get_neighbors_json(char *out_json, uint32_t max_len)
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        std::ostringstream ss;
        ss << "[";
        bool first = true;
        for (auto &kv : g_neighbors)
        {
            const Neighbor &n = kv.second;
            if (!first)
                ss << ",";
            first = false;
            ss << "{";
            ss << "\"device_id\":\"" << n.device_id << "\",";
            ss << "\"address\":\"" << n.address << "\",";
            ss << "\"rssi\":" << n.rssi << ",";
            ss << "\"last_seen\":" << n.last_seen;
            ss << "}";
        }
        ss << "]";
        string s = ss.str();
        if (s.size() + 1 > max_len)
            return -1;
        memcpy(out_json, s.c_str(), s.size() + 1);
        return (int)s.size();
    }

#ifdef __cplusplus
}
#endif
