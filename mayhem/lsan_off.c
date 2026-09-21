/* mayhem/lsan_off.c — disable LeakSanitizer at BUILD time for every fuzz target.
 *
 * `-Zsanitizer=address` always bundles LSan into ASan; there is no flag that keeps
 * ASan's memory-corruption checks while dropping just leak detection. Leaks are not
 * the bug class this fleet fuzzes for, and LSan's at-exit scan is both noisy on
 * Rust arena/`Box::leak` patterns and conflicts with Mayhem's coverage tracer.
 *
 * ASan calls this weak hook at startup; a strong definition linked into the binary
 * wins. This is the ONLY sanctioned way to turn LSan off (SPEC §6.2): NOT a runtime
 * disable/enable wrap, and NOT a compiled-in sanitizer-options override function —
 * Mayhem alone owns the ASAN_OPTIONS/LSAN_OPTIONS environment.
 *
 * mayhem/build.sh compiles this and prepends the object to every rustc link via the
 * -Clinker wrapper, so it lands in all 75 fuzz binaries.
 */
int __lsan_is_turned_off(void) { return 1; }
