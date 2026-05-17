#pragma once

#include <mutex>

#include "duckdb/common/helper.hpp"
#include "duckdb/function/cast/default_casts.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "mobilityduck/meos_error_guard.hpp"
#include "mobilityduck/meos_exec_serial.hpp"

namespace duckdb {

// DuckDB cast functions are raw `cast_function_t` pointers, not std::function,
// so they cannot be wrapped by a capturing lambda the way serialized scalar
// functions are (see meos_exec_serial.hpp). To run a MEOS-backed cast inside
// the longjmp landing pad we carry the original function pointer in the
// per-cast BoundCastData payload and dispatch through one generic trampoline.
// Without this, a MEOS error during a VARCHAR -> mobility-type cast unwinds a
// C++ exception through MEOS C frames (undefined behaviour -> the documented
// non-deterministic cast SIGSEGV).
struct MeosGuardedCastData : public BoundCastData {
	explicit MeosGuardedCastData(cast_function_t orig_p) : orig(orig_p) {
	}
	cast_function_t orig;
	unique_ptr<BoundCastData> Copy() const override {
		return make_uniq<MeosGuardedCastData>(orig);
	}
};

inline bool MeosGuardedCastTrampoline(Vector &source, Vector &result, idx_t count,
                                      CastParameters &parameters) {
	cast_function_t orig = parameters.cast_data->Cast<MeosGuardedCastData>().orig;
	bool ok = true;
	// MEOS global state (the pg-derived session timezone and its transition
	// cache reached via timestamp2tm/localsub, plus the legacy GEOS context)
	// is not thread-safe. Casts must take the SAME serialization mutex as
	// scalar functions (meos_exec_serial.hpp), otherwise a cast parsing a
	// timestamp on one DuckDB worker thread races a scalar's
	// tinstant_to_string on another -> SIGSEGV in localsub. Mutex outside the
	// guard so it is released by normal unwinding if the guard throws.
	std::lock_guard<std::mutex> serialize(MeosSerializedExecMutex());
	MeosGuardedRun([&]() { ok = orig(source, result, count, parameters); });
	return ok;
}

// Drop-in replacement for `loader.RegisterCastFunction(source, target, fn[, cost])`
// that runs `fn` inside the MEOS longjmp guard. Cost default mirrors DuckDB's
// own RegisterCastFunction default (-1).
inline void RegisterGuardedCastFunction(ExtensionLoader &loader, const LogicalType &source,
                                        const LogicalType &target, cast_function_t orig,
                                        int64_t implicit_cast_cost = -1) {
	loader.RegisterCastFunction(
	    source, target,
	    BoundCastInfo(MeosGuardedCastTrampoline, make_uniq<MeosGuardedCastData>(orig)),
	    implicit_cast_cost);
}

} // namespace duckdb
