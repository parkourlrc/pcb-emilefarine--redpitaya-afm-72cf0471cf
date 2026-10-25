#pragma once

#include "IRedPitayaHardware.h"

#include <cstddef>
#include <cstdint>
#include <sys/types.h>
#include <vector>

/**
 * @brief Hardware implementation for RedPitaya FPGA-based signal generation
 *        and acquisition via /dev/mem
 *
 * Memory map (from measure_api.c):
 * - 0x40600000: BRAM_SHARED (generation + acquisition, in-place overwrite, 65536 samples max, 256KB window)
 * - 0x40640000: Control registers
 *
 * Both windows are mapped once in initialize() and accessed through raw
 * pointers, which avoids a mmap/munmap syscall pair per 4-byte sample.
 */

class RedPitayaHardware : public IRedPitayaHardware
{
public:
  RedPitayaHardware();
  ~RedPitayaHardware() override;

  RedPitayaHardware(const RedPitayaHardware&) = delete;
  RedPitayaHardware& operator=(const RedPitayaHardware&) = delete;

  bool initialize() override;
  void cleanup() override;

  // Signal generation (DAC)
  bool loadGenerationSignal(const std::vector<float>& signal) override;

  // Decimation control
  bool setDecimation(uint16_t decimation) override;
  uint16_t getDecimation() const override;

  // Signal acquisition (ADC)
  bool startMeasurement(uint32_t numSamples, uint32_t delaySamples = 0) override;
  bool isMeasurementComplete() override;
  bool getAcquiredSignal(std::vector<float>& signal) override;
  bool isAdcOverrange() override;

  bool resetMeasurement() override;

private:
  bool _mapWindows();
  void _unmapWindows();

  uint32_t _readVersion() const;
  uint32_t _readStatus() const;
  bool _clearStatus(); // Clears the sticky ps_access_denied flag

  bool _isMapped() const;

  int m_memFd;
  uint16_t m_decimation; // Current decimation factor (16-1024)
  volatile uint32_t* m_regs; // Control register page
  volatile uint32_t* m_bram; // Shared BRAM window (MAX_SAMPLES words)

  static constexpr off_t BRAM_SHARED_BASE = 0x40600000;
  static constexpr off_t REG_BASE = 0x40640000;

  // VERSION register of fpga/bitfiles/red_pitaya_top_25102026.bit.bin
  static constexpr uint32_t FPGA_VERSION = 0x25102026;

  static constexpr uint32_t REG_START_MEASURE = 2;
  static constexpr uint32_t REG_DELAY = 3;
  static constexpr uint32_t REG_SIG_SIZE = 4;
  static constexpr uint32_t REG_END_MEASURE = 5;
  static constexpr uint32_t REG_COUNT_MEASURE = 6; // Samples written, held until the next START
  static constexpr uint32_t REG_VERSION = 7;       // Read-only version register (date of bitfile)
  static constexpr uint32_t REG_DECIMATION = 8;
  static constexpr uint32_t REG_STATUS = 9; // [0]=busy, [1]=ps_access_denied, [2]=overrange

  static constexpr uint32_t STATUS_BUSY_BIT = 0x01;             // FSM in RUNNING state
  static constexpr uint32_t STATUS_PS_ACCESS_DENIED_BIT = 0x02; // PS accessed BRAM while busy
  static constexpr uint32_t STATUS_OVERRANGE_BIT = 0x04;        // Sticky, only START clears it

  static constexpr std::size_t REG_WINDOW_SIZE = 4096UL;
  static constexpr std::size_t BRAM_WINDOW_SIZE =
      static_cast<std::size_t>(MAX_SAMPLES) * sizeof(uint32_t); // 256 KB
};
