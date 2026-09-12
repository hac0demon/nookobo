# GitHub publication checklist

The repository has no configured remote by default. Before publishing, create
an empty GitHub repository and add its URL locally:

```sh
git remote add origin git@github.com:<account>/<repository>.git
git branch -M main
```

Review the publication set before committing. The following are source and
documentation and should be included:

```sh
git add AGENTS.md Makefile README.md LICENSE .gitignore \
  components docs mk packaging scripts tests toolchains
git diff --cached --check
git status --short
```

Do not add `build/`, `staging/`, `downloads/`, `dl_test/`, `glibc_libs/`,
`magiskboot/`, `workspace/`, device boot images, or generated logs. They are
ignored because they contain large/reproducible artifacts or device-specific
data.

Commit and publish only after the checks pass:

```sh
make test
git commit -m "Organize BNRV700 components and reproducible deployment"
git push -u origin main
```

For a release, attach the generated `build/boot_linux.img` and
`build/deploy_payload.tar.gz` separately if desired; do not put them in the
source history. Record their SHA-256 values and the source revision used to
build them.
