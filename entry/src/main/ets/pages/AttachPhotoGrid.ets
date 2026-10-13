// 附件面板内的系统图库网格（免权限 PhotoPickerComponent）。
// 对位 iOS AttachmentController 内嵌的 MediaPickerScreen：三列缩略图网格，
// 首格相机（isPhotoTakingSupported），最多选择 9 项后统一回传给仓颉发送。
import { PhotoPickerComponent, PickerOptions, PickerController, SelectMode, PickerColorMode, ReminderMode }
  from '@ohos.file.PhotoPickerComponent';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { copyMediaUriToSandbox } from '../interop/impls/PhotoPickerImpl';
import { resolveAttachPick } from '../interop/impls/AttachGridImpl';

@Component
export struct AttachPhotoGrid {
  // PhotoPickerComponent 的 pickerController 是 @ObjectLink 必填项，
  // 需由父组件以 @State 持有一个 @Observed 的 PickerController 实例。
  @State pickerController: PickerController = new PickerController();
  @State selectedUris: string[] = [];

  private buildOptions(): PickerOptions {
    const o: PickerOptions = new PickerOptions();
    o.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
    o.maxSelectNumber = 9;
    o.maxPhotoSelectNumber = 9;
    o.maxVideoSelectNumber = 9;
    o.selectMode = SelectMode.MULTI_SELECT;
    o.isSlidingSelectionSupported = true;
    // 点击缩略图直接切换选择状态，不先进系统预览页。
    o.singleSelectionMode = photoAccessHelper.SingleSelectionMode.SELECT_MODE;
    // iOS 图库网格首格是相机取景格，这里用系统选择器自带的拍照格对齐
    o.isPhotoTakingSupported = true;
    // iOS 的 sheet 里没有搜索条，关掉可多露一行缩略图
    o.isSearchSupported = false;
    o.uiComponentColorMode = PickerColorMode.LIGHT;
    o.maxSelectedReminderMode = ReminderMode.NONE;
    return o;
  }

  private selected(uri: string): void {
    if (this.selectedUris.indexOf(uri) >= 0) {
      return;
    }
    this.selectedUris = this.selectedUris.concat([uri]);
  }

  private deselected(uri: string): void {
    this.selectedUris = this.selectedUris.filter((item: string): boolean => item !== uri);
  }

  private isVideo(uri: string): boolean {
    const lower: string = uri.toLowerCase().split('?')[0];
    return lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.m4v')
      || lower.endsWith('.3gp') || lower.endsWith('.mkv');
  }

  private sendSelected(): void {
    const paths: string[] = [];
    const kinds: string[] = [];
    for (let i: number = 0; i < this.selectedUris.length; i++) {
      const uri: string = this.selectedUris[i];
      const video: boolean = this.isVideo(uri);
      const path: string = copyMediaUriToSandbox(uri, i, video ? '.mp4' : '.jpg');
      if (path.length > 0) {
        paths.push(path);
        kinds.push(video ? 'video' : 'photo');
      }
    }
    if (paths.length > 0) {
      this.selectedUris = [];
      resolveAttachPick(paths, kinds);
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      PhotoPickerComponent({
        pickerOptions: this.buildOptions(),
        pickerController: this.pickerController,
        onSelect: (uri: string): void => {
          this.selected(uri);
        },
        onDeselect: (uri: string): void => {
          this.deselected(uri);
        }
      })
        .width('100%')
        .height('100%');

      if (this.selectedUris.length > 0) {
        Button(`Send ${this.selectedUris.length}`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .height(44)
          .padding({ left: 20, right: 20 })
          .margin({ right: 14, bottom: 12 })
          .borderRadius(22)
          .backgroundColor('#007AFF')
          .shadow({ radius: 10, color: '#40000000', offsetY: 3 })
          .onClick((): void => {
            this.sendSelected();
          });
      }
    }
    .width('100%')
    .height('100%')
    .clip(true);
  }
}
