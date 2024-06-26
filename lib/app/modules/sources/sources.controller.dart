import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_rich_text/easy_rich_text.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:rss_dart/domain/atom_feed.dart';
import 'package:rss_dart/domain/rss1_feed.dart';
import 'package:rss_dart/domain/rss_feed.dart';
import 'package:work/app/data/beans/reader_data_entity.dart';
import 'package:work/app/data/beans/source_icon_entity.dart';
import 'package:work/app/data/collections/reader_data.dart';
import 'package:work/app/data/collections/source.dart';
import 'package:work/app/data/db/db_server.dart';
import 'package:work/app/modules/home/home.view.dart';
import 'package:work/app/plugin/reader_data_manager.dart';
import 'package:work/app/utils/common_utils.dart';
import 'package:work/app/utils/dialog_util.dart';
import 'package:work/app/utils/stream_util.dart';

class SourcesController extends GetxController {
  /// 无头浏览器
  HeadlessInAppWebView? headlessWebView;

  var curStep = 1.obs;

  final dio = Dio();

  /// 解析规则
  var ruleHtml = "".obs;

  /// 解析 Title
  var ruleTitle = "".obs;

  Source source = Source();

  /// 输入控制器
  final TextEditingController urlEditController = TextEditingController();

  final TextEditingController nameEditController = TextEditingController();

  @override
  Future<void> onInit() async {
    super.onInit();
  }

  @override
  void onReady() {
    super.onReady();
  }

  @override
  void onClose() {
    headlessWebView?.dispose();
    super.onClose();
  }

  /// 选择规则，实际上就是单个的 Html 文件
  /// 输入源可以是[默认设置],[链接],[本地文件],[字符串文本]
  /// 最终都会转成 String 存入数据库
  /// TODO 这里现暂时只从 assets 取，用作测试
  Future<void> chooseRule() async {
    // TODO 弹出选择弹窗
    DialogUtil.bottomSheet(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () async {
            Get.back();
            FilePickerResult? result = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['html', 'HTML'],
            );

            if (result != null) {
              print("chooseRule --> [${result.files.single.path!}]");
              String htmlData = await File(result.files.single.path!).readAsString();
              await _addRuleHtmlData(htmlData);
            } else {
              DialogUtil.showToast("取消了选择");
            }
          },
          child: Container(
            width: double.infinity,
            height: 50,
            child: Center(child: Text("本地文件")),
          ),
        ),
        GestureDetector(
          onTap: () async {
            Get.back();
            String htmlData = await rootBundle.loadString('assets/rules/rsshub.html');
            await _addRuleHtmlData(htmlData);
          },
          child: Container(
            width: double.infinity,
            height: 50,
            child: Center(child: Text("默认 RSS 规则")),
          ),
        ),
        GestureDetector(
          onTap: () {
            Get.back();
            DialogUtil.showToast("施工中");
          },
          child: Container(
            width: double.infinity,
            height: 50,
            child: Center(child: Text("网络 url")),
          ),
        ),
        SizedBox(
          height: 50,
        )
      ],
    ));
  }

  Future<void> _addRuleHtmlData(String htmlData) async {
    DialogUtil.showLoading();
    // 创建无头浏览器
    await headlessWebView?.dispose();
    headlessWebView = HeadlessInAppWebView(
        initialData: InAppWebViewInitialData(data: htmlData, baseUrl: WebUri(CommonUtils.getHostLink(urlEditController.text))),
        initialSettings: InAppWebViewSettings(
          isInspectable: kDebugMode,
          allowUniversalAccessFromFileURLs: true,
          allowFileAccessFromFileURLs: true,
        ),
        onWebViewCreated: (controller) {
          /// 监听 js 返回
          /// 成功
          controller.addJavaScriptHandler(
              handlerName: 'reader-success',
              callback: (result) {
                // print("getReaderData:--->\n$result");
                if (result.isNotEmpty) {
                  ReaderDataManager.resultStream.add(result[0]);
                } else {
                  ReaderDataManager.resultStream.add([]);
                }
              });

          /// 失败
          controller.addJavaScriptHandler(
              handlerName: 'reader-fail',
              callback: (_) {
                ReaderDataManager.resultStream.add([]);
              });
        },
        onConsoleMessage: (_, consoleMessage) {
          print("onConsoleMessage:[$consoleMessage]");
          if (consoleMessage.messageLevel == ConsoleMessageLevel.ERROR) {
            ReaderDataManager.resultStream.add([]);
          }
        },
        onLoadStart: (_, url) async {
          print("onLoadStart:[$url]");
        },
        onLoadStop: (controller, url) async {
          print("onLoadStop:[$url]");
          DialogUtil.hideLoading();
          ruleHtml.value = htmlData;
          ruleTitle.value = await controller.getTitle() ?? "Unknown title";
          DialogUtil.showToast("添加完毕");
        },
        onReceivedError: (_, __, ___) async {
          DialogUtil.showLoading();
          DialogUtil.showToast("出错了");
        });
    await headlessWebView?.run();
  }

  /// 获取数据，校验完成后并添加
  void saveSource() async {
    if (headlessWebView?.isRunning() ?? false) {
      DialogUtil.showLoading();
      Mutex mtx = MutexFactory.getMutexForKey("getReaderData");
      await mtx.take();

      try {
        final sourceUrl = urlEditController.text;
        var responseStream = ReaderDataManager.resultStream.stream;
        Future<List<dynamic>> futureResponse = responseStream.first;
        await headlessWebView?.webViewController?.evaluateJavascript(source: "getReaderData('$sourceUrl')");

        // 等待getReaderData返回
        List<dynamic> response = await futureResponse.timeout(const Duration(seconds: 5 * 60), onTimeout: () => []);
        print("=============START===============");
        List<ReaderDataEntity> entities = [];
        List<ReaderData> readDataList = [];
        for (var data in response) {
          var entity = ReaderDataEntity.fromJson(data);
          print("entity --> [$entity]");
          if (entity.url?.isNotEmpty == true) {
            entities.add(entity);
          }
        }
        print("=============END===============");
        // 校验内部格式是否正确，必填字段是否存在
        if (entities.isEmpty) {
          DialogUtil.showToast("数据为空，校验失败，请检查返回格式是否正确？");
        } else {
          // 存入 Source 数据库
          Source dbSource = Source()
            ..url = sourceUrl
            ..ruleCode = ruleHtml.value
            ..ruleName = ruleTitle.value
            ..name = source.name
            ..icon = source.icon
            ..link = source.link
            ..lastUpdateTime = DateTime.now().millisecondsSinceEpoch
            ..updateResultType = LastUpdateType.success;
          var dbRes1 = await DBServerSource.inserts([dbSource]);
          // 将获取到的数据也存入
          for (var entity in entities) {
            readDataList.add(entity.toReaderData(dbSource)..listType = ListType.library);
          }
          var dbRes2 = await DBServerReaderData.inserts(readDataList);
          print("DBServerSource:[$dbRes1]/[$dbSource] DBServerReaderData:[$dbRes2]/[${readDataList.length}]");
          DialogUtil.showToast("已存入");
          Get.back();
        }
      } finally {
        mtx.give();
        DialogUtil.hideLoading();
      }
    } else {
      DialogUtil.showToast("规则运行失败，请重试");
    }
  }

  /// 请求数据源信息，确认是否能正常访问
  requestSource() async {
    source = Source();
    try {
      DialogUtil.showLoading();
      var url = urlEditController.text;
      final response = await dio.get(url);
      print("requestSource:--> [${response.data.toString()}]");

      RssFeed? rssFeed;
      AtomFeed? atomFeed;
      Rss1Feed? rss1Feed;

      try {
        rssFeed = RssFeed.parse(response.data.toString());
        atomFeed = AtomFeed.parse(response.data.toString());
        rss1Feed = Rss1Feed.parse(response.data.toString());
      } catch (_) {}

      print("rssFeed:--> [${rssFeed?.title}]  [${rssFeed?.link}] [${rssFeed?.description}]");
      print("atomFeed:--> [$atomFeed]");
      print("rss1Feed:--> [$rss1Feed]");

      source.url = url;
      source.name = rssFeed?.title;
      source.link = rssFeed?.link;

      // TODO 获取 icon
      // https://besticon-demo.herokuapp.com/allicons.json?url=https%3a%2f%2fsspai.com
      try {
        var url = '''https://besticon-demo.herokuapp.com/allicons.json?url=${rssFeed?.link}''';
        print("url:--> [$url]");
        final rsp = await dio.get(url);
        SourceIconEntity entity = SourceIconEntity.fromJson(rsp.data);
        print("entity:--> [$entity]");
        if (entity.icons?.isNotEmpty == true) {
          for (var data in entity.icons!) {
            if (data.format == "png" || data.format == "jpg") {
              source.icon = data.url!;
              break;
            }
          }
        }
      } catch (e) {
        print("获取icon失败:$e");
      }

      print("获取完毕");

      curStep.value = 2;
      nameEditController.text = source.name ?? "unknown";
    } catch (e) {
      DialogUtil.showToast("请求失败，请确认网络和 url 是否可以正常访问");
    } finally {
      DialogUtil.hideLoading();
    }
  }

  /// 查看规则代码
  showCodeView() {
    DialogUtil.bottomSheet(SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 32),
        child: EasyRichText(
          ruleHtml.value,
          patternList: [
            EasyRichTextPattern(
              targetString: "function",
              style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold),
            ),
            EasyRichTextPattern(
              targetString: "getReaderData",
              style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    ));
  }
}
