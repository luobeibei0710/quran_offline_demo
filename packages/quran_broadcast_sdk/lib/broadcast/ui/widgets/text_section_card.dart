/// 三栏共用的文本卡片：标题、状态副标题、来源标记与正文。
///
/// 三类文本（识别转写 / 匹配经文 / 目标译文）在视觉上必须能区分，且各自
/// 标注来源与范围，避免「转写被当成经文」「机器翻译被当成校订译本」。
library;

import 'package:flutter/material.dart';

/// 文本区域卡片。
class TextSectionCard extends StatelessWidget {
  /// 构造卡片。
  ///
  /// @param title 区域标题（如「识别转写」）
  /// @param subtitle 状态副标题（语言、状态、范围）
  /// @param body 正文；为空时显示 [emptyHint]
  /// @param emptyHint 无内容时的提示
  /// @param rtl 正文是否为从右到左排版
  /// @param badge 来源标记文案
  /// @param badgeColor 来源标记颜色
  /// @param footnote 底部补充说明
  /// @param onRetry 重试回调（为空时不显示按钮）
  /// @param retryLabel 重试按钮文案
  const TextSectionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.body,
    this.emptyHint,
    this.rtl = false,
    this.badge,
    this.badgeColor,
    this.footnote,
    this.onRetry,
    this.retryLabel = '重试翻译',
  });

  /// 区域标题。
  final String title;

  /// 状态副标题。
  final String subtitle;

  /// 正文。
  final String body;

  /// 无内容提示。
  final String? emptyHint;

  /// 是否 RTL。
  final bool rtl;

  /// 来源标记。
  final String? badge;

  /// 来源标记颜色。
  final Color? badgeColor;

  /// 底部补充说明。
  final String? footnote;

  /// 重试回调。
  final VoidCallback? onRetry;

  /// 重试按钮文案。
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trimmed = body.trim();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                if (badge != null && badge!.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (badgeColor ?? theme.colorScheme.primary).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badge!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: badgeColor ?? theme.colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const Divider(height: 16),
            if (trimmed.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  emptyHint ?? '暂无内容',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
                ),
              )
            else
              Directionality(
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                child: SelectableText(
                  trimmed,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    height: rtl ? 2.0 : 1.5,
                    fontSize: rtl ? 22 : null,
                  ),
                ),
              ),
            if (footnote != null && footnote!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                footnote!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ],
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(retryLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
