import 'package:piliplus/grpc/bilibili/app/viewunite/v1.pb.dart'
    show ViewReq, ViewReply;
import 'package:piliplus/grpc/grpc_req.dart';
import 'package:piliplus/grpc/url.dart';
import 'package:piliplus/http/loading_state.dart';

abstract final class ViewGrpc {
  static Future<LoadingState<ViewReply>> view({
    required String bvid,
  }) {
    return GrpcReq.request(
      GrpcUrl.view,
      ViewReq(bvid: bvid),
      ViewReply.fromBuffer,
    );
  }
}
