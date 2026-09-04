/// Backend base URL per environment. Only `development` has a real value
/// today — the ResQNet backend has not been deployed yet (see
/// docs/AUDIT.md / docs/PLAN.md open questions: domain, GitHub org, VPS
/// port block are still unconfirmed). `staging`/`production` are
/// placeholders to fill in once Phase 18 (Hostinger deployment) lands —
/// intentionally not guessed at here.
enum ResQNetEnvironment { development, staging, production }

class ApiConfig {
  const ApiConfig._();

  static const ResQNetEnvironment current = ResQNetEnvironment.development;

  static String get baseUrl {
    switch (current) {
      case ResQNetEnvironment.development:
        // Android emulator's alias for the host machine's localhost.
        // Override at run time with --dart-define=API_BASE_URL=... for a
        // physical device pointed at a LAN-reachable dev backend.
        return const String.fromEnvironment(
          'API_BASE_URL',
          defaultValue: 'http://10.0.2.2:4000',
        );
      case ResQNetEnvironment.staging:
        throw UnsupportedError(
          'Staging backend URL is not configured yet — see docs/AUDIT.md open questions (domain).',
        );
      case ResQNetEnvironment.production:
        throw UnsupportedError(
          'Production backend URL is not configured yet — see docs/AUDIT.md open questions (domain).',
        );
    }
  }

  static Uri resolve(String path) => Uri.parse('$baseUrl/api/v1$path');
}
