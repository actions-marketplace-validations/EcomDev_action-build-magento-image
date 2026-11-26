# Changelog

## [2.0.0](https://github.com/EcomDev/action-build-magento-image/compare/v1.0.1...v2.0.0) (2026-11-26)


### ⚠ BREAKING CHANGES

* MariaDB and MySQL images are now minimal FROM scratch containers without CLI client tools, bash (MariaDB), or upstream docker-entrypoint.sh; pushed images default to OCI zstd layer compression (set compression: gzip for legacy runtimes); artifact downloads use token instead of password and cache defaults to false.

### Features

* add MYSQL_ENABLE_BINLOG runtime toggle and fix MySQL AppArmor builds ([e090795](https://github.com/EcomDev/action-build-magento-image/commit/e090795707217abc0266524bf8646f8c9609025b))
* build minimal scratch MariaDB and MySQL testcontainer images ([d450fc9](https://github.com/EcomDev/action-build-magento-image/commit/d450fc942006ee4138d4b7504eefc4e449d3c45f))
* enable zstd OCI layer compression by default when pushing images ([eba1c46](https://github.com/EcomDev/action-build-magento-image/commit/eba1c46c87c89af879438a5f107e23fd01267930))
* Minimalistic Opensearch Container ([83bdae2](https://github.com/EcomDev/action-build-magento-image/commit/83bdae217c160a2939b5ac5cdd10d67ba82967fe))
* support data-artifact v2 multi-stage builds and optional OpenSearch ([d2e6bf8](https://github.com/EcomDev/action-build-magento-image/commit/d2e6bf83aa782f2523c49504c10b10f68dbd6532))


### Bug Fixes

* bypass host AppArmor usr.sbin.mysqld attachment during MySQL builds ([03fa407](https://github.com/EcomDev/action-build-magento-image/commit/03fa4079e1083da69766324e1cc56fdc49fe648c))
* drop empty SSL path flags for MariaDB 10.11 compatibility in init-db.sh ([ebbc864](https://github.com/EcomDev/action-build-magento-image/commit/ebbc8645729f6dbf05b7f35120d127a794b03562))
* missing test file ([1dfba6a](https://github.com/EcomDev/action-build-magento-image/commit/1dfba6a26461826e1fb7b5a388ccd34f16675bf2))
* support JDK 24+ JEP 493 runtimes without jmods in OpenSearch rootfs build ([4a429ff](https://github.com/EcomDev/action-build-magento-image/commit/4a429ff127872ecbbecd2277ecb3ff4ccd7aab22))


### Documentation

* breaking changes in Dockerfile image build process and update usage examples to v2.0.0 ([929ba5c](https://github.com/EcomDev/action-build-magento-image/commit/929ba5c4562ab7d5c375fb3adb3fbf06704ec880))

## [1.0.1](https://github.com/EcomDev/action-build-magento-image/compare/v1.0.0...v1.0.1) (2026-11-18)


### Bug Fixes

* move attestations to docker build action ([5c41c1c](https://github.com/EcomDev/action-build-magento-image/commit/5c41c1cddc8ddebba8aacf6f67330de2cf35302e))
* pin version for external actions ([1000ac5](https://github.com/EcomDev/action-build-magento-image/commit/1000ac5b8c8e6180a9261e6a11db89c3345ed914))

## 1.0.0 (2026-11-18)


### Features

* GitHub action for building magento docker data image ([a8a76b9](https://github.com/EcomDev/action-build-magento-image/commit/a8a76b9bdc526c4b1c5ddd9624d1e1c3a7f66fd2))
* Media files support ([8c2fcc5](https://github.com/EcomDev/action-build-magento-image/commit/8c2fcc5c2969db2e35fe1cd98a9f8230039550a4))
* MySQL and MariaDB support ([b04fd99](https://github.com/EcomDev/action-build-magento-image/commit/b04fd99fa330c26523b984f13a4786c96457933d))
* OpeanSearch support ([824e28f](https://github.com/EcomDev/action-build-magento-image/commit/824e28f832edd31d37867a40b25c79d8a96b2ad7))


### Bug Fixes

* missing permission mode for chmod in media image ([fc4680b](https://github.com/EcomDev/action-build-magento-image/commit/fc4680b0d1f5dd10befc5dce0a813a5525f91ac1))
* wrong syntax for chmod ([82ca578](https://github.com/EcomDev/action-build-magento-image/commit/82ca578da7df3160dd6ce60a10b53394d2de381a))
