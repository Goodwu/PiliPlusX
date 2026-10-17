import 'package:piliplus/http/loading_state.dart';
import 'package:piliplus/http/user.dart';
import 'package:piliplus/models_new/follow/data.dart';
import 'package:piliplus/pages/follow_type/controller.dart';

class FollowedController extends FollowTypeController {
  @override
  Future<LoadingState<FollowData>> customGetData() =>
      UserHttp.followedUp(mid: mid, pn: page);
}
