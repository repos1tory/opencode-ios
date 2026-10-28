// Minimal iOS battery reader for the OpenCode web UI title.
//
// Prints one JSON object, e.g.
//   {"ok":true,"level":11,"charging":false,"present":true,"minutes":64,
//    "state":"Battery Power","basis":"raw"}
//
// The percentage comes from the usable gauge capacities:
//
//   AppleRawCurrentCapacity / AppleRawMaxCapacity
//
// The legacy IOPowerSources "Current Capacity" is a percentage of the *design*
// capacity, so a degraded battery reads low (10% when the device is at 12%).
// AbsoluteCapacity / BatteryData.StateOfCharge include the low-battery reserve
// and over-report (18% for the same charge), which is why those are only a last
// resort. The usable ratio matches powerd's notify state, the system's time
// remaining estimate, and BatteryCenter's display rounding.
//
// The PS headers are not part of the on-device SDK, so the three functions are
// declared here and the string keys are the documented CFString values.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdio.h>

typedef const void *IOPSBlob;

extern IOPSBlob IOPSCopyPowerSourcesInfo(void);
extern CFArrayRef IOPSCopyPowerSourcesList(IOPSBlob blob);
extern CFDictionaryRef IOPSGetPowerSourceDescription(IOPSBlob blob, CFTypeRef source);

static long long numberValue(CFDictionaryRef d, CFStringRef key, long long fallback) {
  if (d == NULL) return fallback;
  CFTypeRef v = CFDictionaryGetValue(d, key);
  if (v == NULL || CFGetTypeID(v) != CFNumberGetTypeID()) return fallback;
  long long out = fallback;
  if (!CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &out)) return fallback;
  return out;
}

static int intValue(CFDictionaryRef d, CFStringRef key, int fallback) {
  long long out = numberValue(d, key, fallback);
  if (out < -2147483647LL || out > 2147483647LL) return fallback;
  return (int)out;
}

static int boolValue(CFDictionaryRef d, CFStringRef key, int fallback) {
  if (d == NULL) return fallback;
  CFTypeRef v = CFDictionaryGetValue(d, key);
  if (v == NULL || CFGetTypeID(v) != CFBooleanGetTypeID()) return fallback;
  return CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
}

static CFDictionaryRef dictionaryValue(CFDictionaryRef d, CFStringRef key) {
  if (d == NULL) return NULL;
  CFTypeRef v = CFDictionaryGetValue(d, key);
  if (v == NULL || CFGetTypeID(v) != CFDictionaryGetTypeID()) return NULL;
  return (CFDictionaryRef)v;
}

// Same rounding as BatteryCenter's display mapping: 11.8 -> 12, 18.4 -> 18.
static int percentOf(long long value, long long maximum) {
  if (maximum <= 0 || value < 0) return -1;
  long long percent = (value * 100 + maximum / 2) / maximum;
  if (percent < 0) return 0;
  if (percent > 100) return 100;
  return (int)percent;
}

static void printString(CFDictionaryRef d, CFStringRef key) {
  if (d == NULL) return;
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
  CFArrayRef list = blob ? IOPSCopyPowerSourcesList(blob) : NULL;
  CFDictionaryRef battery = NULL;
  CFDictionaryRef description = NULL;
  CFIndex count = list ? CFArrayGetCount(list) : 0;

  for (CFIndex i = 0; i < count; i++) {
    CFDictionaryRef d = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, i));
    if (d == NULL) continue;
    if (description == NULL) description = d;
    CFTypeRef type = CFDictionaryGetValue(d, CFSTR("Type"));
    if (type && CFGetTypeID(type) == CFStringGetTypeID() &&
        CFStringCompare((CFStringRef)type, CFSTR("InternalBattery"), 0) == kCFCompareEqualTo) {
      description = d;
      battery = d;
      break;
    }
  }
  if (battery == NULL) battery = description;

  io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMPowerSource"));
  CFMutableDictionaryRef properties = NULL;
  if (service) {
    IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
    IOObjectRelease(service);
  }
  CFDictionaryRef gauge = dictionaryValue(properties, CFSTR("BatteryData"));

  int present = boolValue(battery, CFSTR("Is Present"), 1);
  int charging = properties ? boolValue(properties, CFSTR("IsCharging"), -1) : -1;
  if (charging < 0) charging = boolValue(battery, CFSTR("Is Charging"), 0);

  const char *basis = "none";
  int level = -1;

  long long raw = numberValue(properties, CFSTR("AppleRawCurrentCapacity"), -1);
  long long rawMax = numberValue(properties, CFSTR("AppleRawMaxCapacity"), -1);
  long long stateOfCharge = numberValue(gauge, CFSTR("StateOfCharge"), -1);
  long long current = numberValue(battery, CFSTR("Current Capacity"), -1);
  long long maximum = numberValue(battery, CFSTR("Max Capacity"), -1);

  if (raw >= 0 && rawMax > 0) {
    level = percentOf(raw, rawMax);
    basis = "raw";
  } else if (current >= 0 && maximum > 0) {
    level = percentOf(current, maximum);
    basis = "iops";
  } else if (stateOfCharge >= 0 && stateOfCharge <= 100) {
    level = (int)stateOfCharge;
    basis = "state-of-charge";
  }

  int minutes = -1;
  if (charging) {
    minutes = intValue(battery, CFSTR("Time to Full Charge"), -1);
  } else {
    minutes = intValue(battery, CFSTR("Time to Empty"), -1);
    if (minutes <= 0) minutes = intValue(properties, CFSTR("TimeRemaining"), -1);
  }

  printf("{\"ok\":%s,\"level\":%d,\"charging\":%s,\"present\":%s,\"minutes\":%d,\"basis\":\"%s\",\"state\":",
         present && level >= 0 ? "true" : "false",
         level,
         charging ? "true" : "false",
         present ? "true" : "false",
         minutes,
         basis);
  printString(battery, CFSTR("Power Source State"));
  printf("}\n");

  if (properties) CFRelease(properties);
  if (list) CFRelease(list);
  if (blob) CFRelease(blob);
  return 0;
}
