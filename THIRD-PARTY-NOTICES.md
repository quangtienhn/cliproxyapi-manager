# Third-Party Notices

This project is licensed under the MIT License (see [LICENSE](LICENSE)). It uses or interacts with the following third-party components. Their licenses apply to those components, not to this project's original code.

## Bundled at runtime

### `yaml` (npm)

- Package: `yaml` 2.9.1
- License: ISC
- Project: <https://github.com/eemeli/yaml>
- Distribution: `server-installer/embedded/yaml-dependency.tar.gz`, extracted into the Account Manager application directory.
- Purpose: parse and update CLIProxyAPI `config.yaml` in `src/sync_secret.js`.

The ISC license permits use, copying, modification, and distribution provided the copyright notice and permission notice are retained. The packaged dependency retains its upstream license metadata in `node_modules/yaml`.

### CLIProxyAPI Manager bundle

- License: MIT
- Distribution: `server-installer/embedded/cliproxyapi-account-manager-v1.0.3.tar.gz`
- Contents: original project code plus the `yaml` dependency.

## Runtime environment (not distributed as source)

### CLIProxyAPI

- Separate upstream project: <https://github.com/router-for-me/CLIProxyAPI>
- License: see the upstream repository.
- This repository does not bundle CLIProxyAPI. It integrates with an existing installation through the loopback Management API.

### Node.js

- License: MIT-style with additional notices.
- Project: <https://nodejs.org>
- Required on the server and used in the add-on container.

### OpenSSH

- License: BSD-style.
- Project: <https://www.openssh.com>
- Used as the server SSH daemon and as `openssh-client` in the add-on image.

### Alpine Linux and APK packages

- The add-on base image is Alpine Linux.
- `openssh-client` and `nodejs` are installed from Alpine repositories.
- Licenses are those of the respective packages. See `/usr/share/licenses` in the image.

### Home Assistant Supervisor and Ingress

- Project: <https://www.home-assistant.io>
- The add-on uses the Supervisor Ingress API and add-on configuration schema.
- Home Assistant is not bundled.

## Build-time tools (not distributed)

### Pillow

- License: HPND (Historical Permission Notice and Disclaimer).
- Project: <https://python-pillow.org>
- Used only by `assets/generate-icon.py` to render the project icon. The generated PNG files are original artwork for this project.

### shellcheck

- License: GPLv3.
- Used only for static analysis during development and CI; not distributed with the project.

### gitleaks

- License: MIT.
- Used only for secret scanning during development and CI; not distributed with the project.

## Trademarks

Home Assistant is a trademark of the Home Assistant project. CLIProxyAPI is the name of its respective project. No endorsement is implied. The icon is original geometric artwork and does not incorporate third-party logos.

If you believe a component is missing from this list, please open an issue so it can be corrected.
