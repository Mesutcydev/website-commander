# Private Cloud Compute (PCC) Revert & Restore Guide — DEPRECATED

> **This two-branch "strip & restore" process is retired.** It kept a
> PCC-stripped `master` and a PCC-bearing `pcc-development` in sync by hand
> (~19 files / ~1200 lines that drift), which is unnecessary: Apple reviews the
> compiled binary + entitlements, not your source tree, so `#if APPLE_FM`
> compile-gating plus a clean entitlements file already produces a clean App
> Store binary from a single branch (verified: the `AppStore` archive built from
> the PCC-bearing branch passes `Scripts/verify-app-store-build.sh`).
>
> **Use [`PCC_Release_Method.md`](PCC_Release_Method.md) instead** — single
> branch, App Store vs PCC differ only by build configuration, gated by the
> verify script.
