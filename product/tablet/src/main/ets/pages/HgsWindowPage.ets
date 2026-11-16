import { WaylandWindowPage } from 'hish_main';

@Entry({ useSharedStorage: true })
@Component
struct Wrapper {
  build() {
    Column() {
      WaylandWindowPage()
    }.width('100%').height('100%')
  }
}
