import 'package:piliplus/http/loading_state.dart';
import 'package:piliplus/http/member.dart';
import 'package:piliplus/models_new/follow/data.dart';
import 'package:piliplus/models_new/follow/list.dart';
import 'package:piliplus/pages/common/search/common_search_controller.dart';

class FollowSearchController
    extends CommonSearchController<FollowData, FollowItemModel> {
  FollowSearchController(this.mid);
  final int mid;

  @override
  Future<LoadingState<FollowData>> customGetData() =>
      MemberHttp.getfollowSearch(
        mid: mid,
        ps: 20,
        pn: page,
        name: editController.value.text,
      );

  @override
  List<FollowItemModel>? getDataList(FollowData response) {
    return response.list;
  }
}
