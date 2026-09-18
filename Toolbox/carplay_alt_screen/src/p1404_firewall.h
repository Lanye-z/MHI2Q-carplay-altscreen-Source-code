/* p1404_firewall.h - runtime-scoped CarPlay type-111 PF aperture. */
#ifndef P1404_FIREWALL_H
#define P1404_FIREWALL_H
#include <stddef.h>
#include <stdint.h>
int p1404_alt111_firewall_open(uint16_t port);
int p1404_alt111_firewall_close(uint16_t port);
int p1404_alt111_firewall_rewrite(const char *rules, uint16_t port, int enable,
                                  char *out, size_t out_cap, int *changed_out);
#endif
