# Release

直配布を前提にしたリリース雛形です。実際の署名と notarization はフル Xcode と Apple Developer 認証情報が入った環境で行います。

## 想定フロー

1. `build_app.sh` で `.app` バンドルを生成する。
2. `sign_app.sh` で同梱 Python ランタイムの実行ファイル・共有ライブラリと `.app` 本体を署名する。
3. `package_dmg.sh` で `DropSort.dmg` を生成する。
4. `notarize_app.sh` で notarization し、`staple_dmg.sh` で stapler を実行する。

Developer ID がまだ無い場合は、`DEVELOPER_ID_APP=-` で ad-hoc 署名し、GitHub Releases 向けの開発者プレビューとして配布できます。

## 必須入力

- `vendor/python-runtime/macos-arm64/`
- `DEVELOPER_ID_APP_HASH` または `DEVELOPER_ID_APP`
- `NOTARY_PROFILE`
- `TEAM_ID`

`vendor/python-runtime/macos-arm64/` は relocatable な arm64 CPython 一式を前提にします。
`apple_fm_sdk` と PyObjC (`Foundation`, `Quartz`, `Vision`) を含む `site-packages` も同梱してください。

`validate-device` は通常の Terminal か、`com.apple.modelmanager` に到達できる sandbox 外の実行環境で回してください。
Codex sandbox のような制約環境では Foundation Models / Vision が false negative になることがあります。

## 例

```bash
release/build_app.sh
DEVELOPER_ID_APP_HASH="<40 hex sha1>" release/sign_app.sh
release/package_dmg.sh
NOTARY_PROFILE="<profile>" TEAM_ID="<team>" release/notarize_app.sh --artifact release/build/DropSort.dmg
release/staple_dmg.sh release/build/DropSort.dmg
```

証明書名をコマンドラインやログに残したくない場合は、`DEVELOPER_ID_APP_HASH` を使って署名してください。

## GitHub プレビュー配布

Developer ID / notarization 前でも、以下の流れで GitHub に公開できます。

```bash
release/build_app.sh
DEVELOPER_ID_APP=- release/sign_app.sh
release/package_dmg.sh
release/prepare_github_release.sh --tag "preview"
```

これで `release/build/github-release/` に以下が生成されます。

- `GITHUB_RELEASE_NOTES.md`
- `github-release-manifest.json`

`GITHUB_RELEASE_NOTES.md` を GitHub Releases の本文に貼り、`DropSort.dmg` を添付してください。
この方法は技術プレビュー向けです。Gatekeeper 警告が出る可能性があります。
