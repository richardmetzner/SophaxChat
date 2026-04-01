## Summary

_What does this PR do? One or two sentences._

## Motivation

_Why is this change needed? Link to the relevant issue if applicable (e.g. Closes #123)._

## Changes

-
-

## Checklist

### Build & tests
- [ ] `swift build` passes with no errors or warnings
- [ ] Existing tests pass (`swift test` or ⌘U in Xcode)
- [ ] New tests added for any new behaviour (especially crypto changes)

### Protocol & compatibility
- [ ] Wire format is backward-compatible, or a versioning mechanism is included
- [ ] No new server dependencies introduced
- [ ] Android interoperability preserved (if touching the wire protocol)

### Security
- [ ] Crypto changes reviewed against the relevant spec (Signal, RFC 9420, etc.)
- [ ] No private key material logged or exposed in error messages
- [ ] New Keychain entries use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- [ ] No new external dependencies added without justification

### Code quality
- [ ] All Swift code compiles under strict concurrency (`-strict-concurrency=complete`)
- [ ] No force-unwraps (`!`) on untrusted external data
- [ ] `private` access used where the symbol does not need cross-file visibility

## Testing notes

_How did you test this? Physical devices used, peer count, any edge cases exercised?_

## Screenshots / recording (if UI change)

_Paste screenshots or a short screen recording here._
