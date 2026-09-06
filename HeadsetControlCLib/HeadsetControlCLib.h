#ifndef HEADSETCONTROLCLIB_H
#define HEADSETCONTROLCLIB_H

#if __has_include(<headsetcontrol/headsetcontrol_c.h>)
#include <headsetcontrol/headsetcontrol_c.h>
#elif __has_include(<headsetcontrol_c.h>)
#include <headsetcontrol_c.h>
#else
#error "headsetcontrol_c.h not found. Install libheadsetcontrol headers."
#endif

// Explicit teardown must happen on the HID manager's owning thread.
#if __has_include(<hidapi/hidapi.h>)
#include <hidapi/hidapi.h>
#elif __has_include(<hidapi.h>)
#include <hidapi.h>
#else
#error "hidapi.h not found. Install hidapi headers."
#endif

#endif
