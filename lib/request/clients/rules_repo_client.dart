import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/ech_adapter.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/services/network/rules_mirror.dart';

class RulesRepoClient {
  RulesRepoClient._();

  static final RulesRepoClient instance = RulesRepoClient._();

  Future<String> getText(String url, {CancelToken? cancelToken}) async {
    final mirror = RulesMirror.current;
    final routed = mirror.map(url) ?? url;
    try {
      final response = await DioFactory.rulesRepoDio.get<String>(
        routed,
        options: Options(
          responseType: ResponseType.plain,
          extra: routed == url ? null : echExtra,
        ),
        cancelToken: cancelToken,
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
