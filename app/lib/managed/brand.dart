abstract final class ManagedBrand {
  static const projectId = String.fromEnvironment('AGENT_PROJECT_ID');
  static const _api = String.fromEnvironment('AGENT_API_BASE_URL');
  static const updateUrl = String.fromEnvironment('AGENT_UPDATE_FEED');
  static const isConfigured = projectId != '' || _api != '';

  static Uri get api {
    final base = Uri.tryParse(_api);
    if (base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{1,78}$').hasMatch(projectId)) {
      throw const FormatException('Invalid managed brand configuration');
    }
    return base.path.endsWith('/') ? base : base.replace(path: '${base.path}/');
  }
}
