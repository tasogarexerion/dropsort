# Publishing

このリポジトリを GitHub に公開するための最短メモです。

## 1. Standalone repo にする

このフォルダ単体で git 管理したい場合は、ここで初期化します。

```bash
cd /Users/taso/開発/オンデバイスAI
git init -b main
```

## 2. 初回公開前チェック

```bash
chmod +x scripts/public_release_check.sh
scripts/public_release_check.sh
```

このチェックでは次を確認します。

- 典型的な秘密情報パターンの簡易検査
- 20 MB 超ファイルの検査
- fixture 生成
- Python テスト
- Swift shell build
- GitHub Releases 用ノート生成の確認

## 3. GitHub にソースコードを公開する

`gh` の認証が通っていれば、次で public repo を作れます。

```bash
gh auth login -h github.com
gh repo create dropsort --public --source=. --remote=origin --push
```

認証状態の確認:

```bash
gh auth status
```

## 4. ad-hoc のプレビュー DMG を公開する

Developer ID がなくても、開発者向けプレビューとしては公開できます。

```bash
release/build_app.sh
DEVELOPER_ID_APP=- release/sign_app.sh
release/package_dmg.sh
release/prepare_github_release.sh --tag "preview-YYYY-MM-DD"
```

生成物:

- `release/build/DropSort.dmg`
- `release/build/github-release/GITHUB_RELEASE_NOTES.md`
- `release/build/github-release/github-release-manifest.json`

GitHub Releases では `GITHUB_RELEASE_NOTES.md` の内容を本文に貼り、DMG を添付します。

## 5. 正式配布に切り替える

Developer ID 証明書と notarization の資格情報が揃ったら、同じアプリを正式配布へ差し替えできます。

```bash
release/build_app.sh
DEVELOPER_ID_APP_HASH="<40 hex sha1>" release/sign_app.sh
release/package_dmg.sh
NOTARY_PROFILE="<profile>" TEAM_ID="<team>" release/notarize_app.sh --artifact release/build/DropSort.dmg
release/staple_dmg.sh release/build/DropSort.dmg
```

## 6. 注意

- このリポジトリのソースコードは `DropSort Community License 1.0` です。
- 個人利用、教育利用、研究利用、評価目的での利用は許可します。
- 商用利用は別途許諾が必要です。利用前にリポジトリ所有者へ問い合わせる前提です。
- `vendor/python-runtime/` と `release/build/` はコミット対象にしない前提です。
- ad-hoc 配布は Gatekeeper の警告が出る前提です。一般ユーザー向け正式配布には向きません。
