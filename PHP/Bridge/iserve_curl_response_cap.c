#include "include/iserve_curl_response_cap.h"

int iserve_curl_response_cap_exceeded(long long bytes_received_so_far)
{
	return bytes_received_so_far > ISERVE_CURL_MAX_RESPONSE_BYTES;
}
