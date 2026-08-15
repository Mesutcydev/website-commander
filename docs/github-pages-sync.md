# GitHub Pages source and synchronization

`website/` in this repository is the canonical Website Commander marketing site. The live portfolio page is [`https://mesut.uk/apps/website-commander`](https://mesut.uk/apps/website-commander), and it should link to this Pages site. The project Pages workflow deploys it directly from `main` at the repository’s Pages URL:

```text
https://mesutcydev.github.io/website-commander/
```

The URL is only available after GitHub Pages is enabled for **GitHub Actions** in the repository settings. The portfolio source at [`Mesutcydev/SiteAgentPage`](https://github.com/Mesutcydev/SiteAgentPage) now links its Website Commander entry to this canonical destination; the existing SiteAgentPage release assets remain available for the iOS sideload build.

## Local preview

From this repository:

```bash
./Scripts/check-website.sh
python3 -m http.server 8080 --directory website
```

Open `http://localhost:8080`. The site uses relative asset paths so it works both as a project Pages site and as the root of a user/organization Pages site.

## Separate `<owner>.github.io` repository

A user/organization Pages repository is not part of this checkout. When it is available, keep the following policy:

1. Treat `website/` here as the source of truth.
2. Synchronize from a reviewed commit or release tag, not from an uncommitted working tree.
3. Preserve destination-only files such as `CNAME`, domain verification files, and intentional redirects.
4. Run the destination repository’s link/HTML checks before deploying.
5. Keep the destination repository’s Pages workflow responsible for the final deployment.

For a local, reviewable copy, run:

```bash
./Scripts/sync-pages-site.sh \
  --source website \
  --destination ../<owner>.github.io
```

The script requires an existing git repository, scopes `rsync --delete` to that destination, preserves common `CNAME` and verification files, and never commits or pushes. Review the resulting diff before publishing.

For automated synchronization, the destination repository can check out a pinned Website Commander commit using a minimally scoped repository secret, copy only the `website/` contents, restore its `CNAME` and verification files, run its validation, and commit through a pull request. Never store a personal access token in this repository or in site source.

## URL and asset paths

A project Pages site is served below `/website-commander/`; a user/organization Pages site is served at the domain root. Keep links and assets relative unless a known custom domain and canonical URL are configured. Do not add an active `CNAME` until the real domain is confirmed.
