return {
  LrSdkVersion = 10.0,
  LrSdkMinimumVersion = 6.0,
  LrToolkitIdentifier = 'com.colortransfer.lightroom',
  LrPluginName = 'Color Transfer',
  LrPluginInfoUrl = 'https://mshiz.github.io/color-transfer/',

  VERSION = { major = 0, minor = 1, revision = 0, build = 0 },

  LrExportMenuItems = {
    {
      title = 'Color Transfer...',
      file = 'ColorTransferMain.lua',
    },
    {
      title = 'Color Transfer: Dump Develop Settings (diagnostic)',
      file = 'DumpDevelopSettings.lua',
    },
  },
}
