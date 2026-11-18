/**
 * @file tests/unit/test_publish.cpp
 * @brief Test src/platform/macos/publish.cpp -- DOCUMENTED GAP, not unit-testable in this pass.
 *
 * The mDNS reliability fix shipped in commit 4bb9c90e (src/platform/macos/publish.cpp:46-73) lives
 * entirely inside a lambda passed to `std::thread{...}` in `deinit_t`'s constructor, which itself
 * is a class defined inside an anonymous namespace:
 *
 *   - `deinit_t` (and everything in it) has internal linkage (anonymous namespace) -- there is
 *     nothing here that could even be forward-declared and linked against from a separate test
 *     translation unit, unlike the confighttp.cpp/nvhttp.cpp pattern used elsewhere in this test
 *     suite (tests/unit/test_confighttp.cpp, tests/unit/test_nvhttp.cpp) where the target function
 *     has external linkage.
 *   - The three fixed behaviors (EINTR retried instead of treated as failure; a successful
 *     `DNSServiceProcessResult()` callback no longer stops the poll loop; an out-of-range socket
 *     fd is rejected before being handed to `select()`) are all inline branches inside that one
 *     lambda body, operating on a real `DNSServiceRef` obtained from a real `DNSServiceRegister()`
 *     call (`start()`, publish.cpp:115) and a real socket fd from `DNSServiceRefSockFD()`. There is
 *     no seam to extract just the branch logic without either (a) editing src/publish.cpp to pull
 *     it out into a pure, testable helper (a src/ change, out of scope for this test-only pass), or
 *     (b) standing up a real (or fake) mDNS responder and a real socket pair to drive `select()`
 *     end to end, which does not exist in this test suite today and would make the "component
 *     under test" mostly the OS's DNS-SD service, not Sunshine's code.
 *
 * This remains INTEGRATION-only coverage. Exact fixed scenarios that would need a real (or
 * carefully faked) DNSServiceRef + socket pair to cover:
 *   - publish.cpp:59-63 -- `select()` returning -1 with `errno == EINTR` must `continue` the poll
 *     loop instead of logging an error and `break`-ing out of it.
 *   - publish.cpp:66-71 -- a successful `select()` wakeup (`ready != 0`) followed by
 *     `DNSServiceProcessResult()` must keep polling (no `break`), since `DNSServiceRegister`
 *     callbacks can legitimately fire more than once (e.g. an initial success followed by a later
 *     rename-on-conflict).
 *   - publish.cpp:48-52 -- `DNSServiceRefSockFD()` returning a value outside `[0, FD_SETSIZE)`
 *     must be rejected before it's passed to `FD_SET()`/`select()`, instead of causing undefined
 *     behavior from indexing outside the `fd_set` bitmap.
 */
