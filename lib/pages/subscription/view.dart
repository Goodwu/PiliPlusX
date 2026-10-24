import 'package:piliplus/common/widgets/flutter/refresh_indicator.dart';
import 'package:piliplus/common/widgets/loading_widget/http_error.dart';
import 'package:piliplus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:piliplus/common/widgets/view_sliver_safe_area.dart';
import 'package:piliplus/http/loading_state.dart';
import 'package:piliplus/models_new/sub/sub/list.dart';
import 'package:piliplus/pages/subscription/controller.dart';
import 'package:piliplus/pages/subscription/widgets/item.dart';
import 'package:piliplus/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SubPage extends StatefulWidget {
  const SubPage({super.key});

  @override
  State<SubPage> createState() => _SubPageState();
}

class _SubPageState extends State<SubPage> with GridMixin {
  final SubController _subController = Get.put(SubController());

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(title: const Text('我的订阅')),
      body: refreshIndicator(
        onRefresh: _subController.onRefresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            ViewSliverSafeArea(
              sliver: Obx(
                () => _buildBody(_subController.loadingState.value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(LoadingState<List<SubItemModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (index == response.length - 1) {
                    _subController.onLoadMore();
                  }
                  final item = response[index];
                  return SubItem(
                    item: item,
                    cancelSub: () => _subController.cancelSub(item),
                  );
                },
                itemCount: response.length,
              )
            : HttpError(onReload: _subController.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _subController.onReload,
      ),
    };
  }
}
