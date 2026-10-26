// Minimal iOS battery reader for the OpenCode web UI widget.
//
// Prints one JSON object, e.g.
//   {"ok":true,"level":87,"charging":false,"state":"Battery Power","minutes":-1}
//
// Uses the public IOPowerSources API. The PS headers are not part of the
// on-device SDK, so the three functions are declared here and the string keys
// are the documented CFString values.

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <math.h>

typedef const void *IOPSBlob;

extern IOPSBlob IOPSCopyPowerSourcesInfo(void);
extern CFArrayRef IOPSCopyPowerSourcesList(IOPSBlob blob);
extern CFDictionaryRef IOPSGetPowerSourceDescription(IOPSBlob blob, CFTypeRef source);

static int intValue(CFDictionaryRef d, CFStringRef key, int fallback) {
  CFTypeRef v = CFDictionaryGetValue(d, key);
  if (v == NULL || CFGetTypeID(v) != CFNumberGetTypeID()) return fallback;
  int out = fallback;
  if (!CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out)) return fallback;
  return out;
}

static int boolValue(CFDictionaryRef d, CFStringRef key, int fallback) {
  CFTypeRef v = CFDictionaryGetValue(d, key);
  if (v == NULL || CFGetTypeID(v) != CFBooleanGetTypeID()) return fallback;
  return CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
}

static void printString(CFDictionaryRef d, CFStringRef key) {
  CFTypeRef v = CFDictionaryGetValue(d, key);
  if (v == NULL || CFGetTypeID(v) != CFStringGetTypeID()) return;
  char buf[128];
  if (!CFStringGetCString((CFStringRef)v, buf, sizeof(buf), kCFStringEncodingUTF8)) return;
  fputc('"', stdout);
  for (const char *p = buf; *p; p++) {
    unsigned char c = (unsigned char)*p;
    if (c == '"' || c == '\\') {
      fputc('\\', stdout);
      fputc(c, stdout);
    } else if (c < 0x20) {
      fprintf(stdout, "\\u%04x", c);
    } else {
      fputc(c, stdout);
    }
  }
  fputc('"', stdout);
}

int main(void) {
  IOPSBlob blob = IOPSCopyPowerSourcesInfo();
  if (blob == NULL) {
    printf("{\"ok\":false,\"error\":\"no power source info\"}\n");
    return 0;
  }
  CFArrayRef list = IOPSCopyPowerSourcesList(blob);
  if (list == NULL || CFArrayGetCount(list) == 0) {
    printf("{\"ok\":false,\"error\":\"no power sources\"}\n");
    if (list) CFRelease(list);
    CFRelease(blob);
    return 0;
  }

  CFDictionaryRef battery = NULL;
  CFIndex count = CFArrayGetCount(list);
  for (CFIndex i = 0; i < count; i++) {
    CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
    if (d == NULL) continue;
    CFTypeRef type = CFDictionaryGetValue(d, CFSTR("Type"));
    if (type && CFGetTypeID(type) == CFStringGetTypeID() &&
        CFStringCompare((CFStringRef)type, CFSTR("InternalBattery"), 0) == kCFCompareEqualTo) {
      battery = d;
      break;
    }
    if (battery == NULL) battery = d;
  }

  if (battery == NULL) {
    printf("{\"ok\":false,\"error\":\"no battery description\"}\n");
    CFRelease(list);
    CFRelease(blob);
    return 0;
  }

  int current = intValue(battery, CFSTR("Current Capacity"), -1);
  int max = intValue(battery, CFSTR("Max Capacity"), -1);
  int present = boolValue(battery, CFSTR("Is Present"), 1);
  int charging = boolValue(battery, CFSTR("Is Charging"), 0);

  int level = -1;
  if (current >= 0 && max > 0) {
    level = (int)llround(((double)current / (double)max) * 100.0);
    if (level < 0) level = 0;
    if (level > 100) level = 100;
  }

  // Time remaining is only meaningful while on battery; time to full only
  // while charging. The system reports -1 when it is still estimating.
  int minutes = charging ? intValue(battery, CFSTR("Time to Full Charge"), -1)
                         : intValue(battery, CFSTR("Time to Empty"), -1);

  printf("{\"ok\":%s,\"level\":%d,\"charging\":%s,\"present\":%s,\"minutes\":%d,\"state\":",
         present && level >= 0 ? "true" : "false",
         level,
         charging ? "true" : "false",
         present ? "true" : "false",
         minutes);
  printString(battery, CFSTR("Power Source State"));
  printf("}\n");

  CFRelease(list);
  CFRelease(blob);
  return 0;
}
