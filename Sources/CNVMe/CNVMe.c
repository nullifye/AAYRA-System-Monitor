#include "CNVMe.h"

#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

static int read_from_service(io_service_t service, AAYRANVMeSMART *out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID,
                                          &plugin, &score) != kIOReturnSuccess || plugin == NULL) {
        return 0;
    }

    int ok = 0;
    IONVMeSMARTInterface **smart = NULL;
    if ((*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart) == S_OK
        && smart != NULL) {
        NVMeSMARTData data;
        memset(&data, 0, sizeof data);
        if ((*smart)->SMARTReadData(smart, &data) == kIOReturnSuccess) {
            out->criticalWarning = data.CRITICAL_WARNING;
            out->temperatureKelvin = data.TEMPERATURE;
            out->availableSpare = data.AVAILABLE_SPARE;
            out->availableSpareThreshold = data.AVAILABLE_SPARE_THRESHOLD;
            out->percentageUsed = data.PERCENTAGE_USED;
            out->dataUnitsRead = data.DATA_UNITS_READ[0];
            out->dataUnitsWritten = data.DATA_UNITS_WRITTEN[0];
            out->powerCycles = data.POWER_CYCLES[0];
            out->powerOnHours = data.POWER_ON_HOURS[0];
            out->unsafeShutdowns = data.UNSAFE_SHUTDOWNS[0];
            out->mediaErrors = data.MEDIA_ERRORS[0];
            ok = 1;
        }
        (*smart)->Release(smart);
    }
    IODestroyPlugInInterface(plugin);
    return ok;
}

int aayra_read_nvme_smart(AAYRANVMeSMART *out) {
    if (out == NULL) return 0;
    memset(out, 0, sizeof *out);

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"),
                                     &iterator) != KERN_SUCCESS) {
        return 0;
    }

    int ok = 0;
    io_service_t service;
    while (!ok && (service = IOIteratorNext(iterator)) != 0) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(service, CFSTR("NVMe SMART Capable"),
                                                            kCFAllocatorDefault, 0);
        if (capable != NULL) {
            if (CFGetTypeID(capable) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)capable)) {
                ok = read_from_service(service, out);
            }
            CFRelease(capable);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return ok;
}
