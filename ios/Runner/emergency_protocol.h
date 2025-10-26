#ifndef emergency_protocol_h
#define emergency_protocol_h

#ifdef __cplusplus
extern "C" {
#endif

void emergency_protocol_init();
int emergency_send_broadcast(const char* message);
int emergency_start_discovery();
int emergency_stop_discovery();

#ifdef __cplusplus
}
#endif

#endif /* emergency_protocol_h */
