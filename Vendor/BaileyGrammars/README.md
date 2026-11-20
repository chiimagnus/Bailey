# Tree-sitter grammars and queries

Bailey retains the 20 parsers and 25 query files it uses from [STTextView-Plugin-Neon at commit 5a30db4](https://github.com/krzyzanowskim/STTextView-Plugin-Neon/tree/5a30db4ce7908a5414e7b499e2379bdc49991cd1), without the STTextView plugin runtime. TSX is maintained separately in `Vendor/TreeSitterTSX`.

The vendored C/C++ scanners use bounded explicit serialization-length conversions and the C# parser header preserves the immutability of its generated name tables; neither changes the grammar data or Tree-sitter ABI.

See [LICENSE](LICENSE) for the original license and [development notes](../../docs/development.md#语法解析与-diff) for integration and updates.
