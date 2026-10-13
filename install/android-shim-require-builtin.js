'use strict';
/**
 * Android shim for node-addon-require-builtin.
 *
 * 背景（实测）：
 *   原实现依赖一个平台特定的 Node-API addon；它只发布了 win32-x64 构建。
 *   DSH 的 boot 阶段会调用它来加载 Node 内部模块：
 *     internal/modules/esm/loader, internal/modules/cjs/loader,
 *     internal/modules/helpers, internal/modules/esm/utils, internal/modules/esm/resolve
 *   在 Android 上拿不到原生绑定，boot 就以
 *     "No usable native binding found for node-addon-require-builtin-android-x64 (auto)"
 *   直接致命退出。
 *
 * 等价替代：
 *   普通 require 在 `--expose-internals` 下同样能加载 internal/* 模块
 *   （cordis-plugin-loader 自己就用这个旁路）。因此这里用标准 require 实现同样三个接口。
 *
 * 局限：Node 内部模块的 API 形状随版本变化；若 DSH 期望的 loader 形状与当前 Node
 * 不匹配，boot 会走它的 "no-internals path"（已有降级逻辑），或需要换用更贴近的 Node 版本。
 */

function requireBuiltin(moduleId) {
  return require(moduleId);
}

/** 与原实现语义一致：只放行内置模块 id（不含路径分隔符）或 internal/* 命名空间。 */
function isAllowedInternalId(moduleId) {
  if (typeof moduleId !== 'string' || moduleId.length === 0) return false;
  if (moduleId.startsWith('internal/')) return true;
  return !moduleId.includes('/');
}

function getBindingInfo() {
  return {
    platform: process.platform,
    arch: process.arch,
    node: process.versions.node,
    mode: 'android-shim',
    native: false,
  };
}

exports.requireBuiltin = requireBuiltin;
exports.isAllowedInternalId = isAllowedInternalId;
exports.getBindingInfo = getBindingInfo;
exports.default = { requireBuiltin, isAllowedInternalId, getBindingInfo };
