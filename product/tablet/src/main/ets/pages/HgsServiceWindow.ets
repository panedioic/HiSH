import { X11WindowPage } from 'hish_main';

@Entry({ useSharedStorage: true })
@Component
struct Wrapper {
  build() {
    Column() {
      X11WindowPage()
    }.width('100%').height('100%')
  }
}
