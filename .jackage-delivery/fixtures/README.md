# Fixture scope

Every file in this directory is a test input or authoring example.
No fixture is a production dependency lock, a trusted channel, or an executable package.
The `.invalid` endpoints intentionally identify nonexistent hosts.
The synthetic artifact digest hashes fixture text, not a compiler or library.

The canonical vectors supply expected bytes and domain-separated digests.
The portable-path vectors describe a conservative cross-platform path policy.
An OS-specific tree can have wider semantics with an explicit materialization contract.
The Python oracle does not implement safe archive extraction or production sandboxing.

## Agent procedure

1. Port the vectors into executable Zig product tests.
2. Implement canonical encoding independently from the Python oracle.
3. Add tests for malformed values and destination-specific behavior.
4. Keep expected vectors independent from the implementation under test.
5. Replace synthetic examples only in actual project declarations, not by pretending their pins are real.
