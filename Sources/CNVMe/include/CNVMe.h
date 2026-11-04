#ifndef CNVME_H
#define CNVME_H

#include <stdint.h>

/// Subset of the NVMe SMART / Health log (NVMe spec 5.14.1.2) for the internal SSD.
typedef struct {
    uint8_t  criticalWarning;       // bit flags; 0 = no warnings
    uint16_t temperatureKelvin;     // composite temperature
    uint8_t  availableSpare;        // percent
    uint8_t  availableSpareThreshold;
    uint8_t  percentageUsed;        // vendor wear estimate; may exceed 100
    uint64_t dataUnitsRead;         // units of 512,000 bytes
    uint64_t dataUnitsWritten;
    uint64_t powerCycles;
    uint64_t powerOnHours;
    uint64_t unsafeShutdowns;
    uint64_t mediaErrors;
} AAYRANVMeSMART;

/// Reads SMART data from the first NVMe SMART–capable drive. Returns 1 on success, 0 otherwise.
int aayra_read_nvme_smart(AAYRANVMeSMART *out);

#endif
