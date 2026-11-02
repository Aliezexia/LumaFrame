import XCTest

final class LumaFrameUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["measureButton"].waitForExistence(timeout: 10))
        var previousFrame = CGRect.zero
        var unchangedSince = Date()
        eventually("首次布局应稳定", timeout: 5) {
            let frame = app.buttons["measureButton"].frame
            if frame != previousFrame { previousFrame = frame; unchangedSince = Date(); return false }
            return frame.width > 0 && Date().timeIntervalSince(unchangedSince) >= 0.5
        }
        return app
    }

    func testDemoMeasureRecordAndSave() {
        let app = launch()
        XCTAssertTrue(element("demoBadge", in: app).exists)
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        attach("23-实时取景")
        measure(app)
        XCTAssertTrue(element("aeLockStatus", in: app).exists)
        attach("01-测光主界面")
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["saveRecord"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveRecord"].isHittable)
        XCTAssertTrue(app.buttons["shareRecord"].isHittable, "分享应位于顶部工具栏")
        attach("02-记录预览")
        app.buttons["saveRecord"].tap()
        allowPhotoAdditionIfPrompted()
        XCTAssertTrue(element("saveSuccess", in: app).waitForExistence(timeout: 30))
        attach("05-保存成功")
        XCTAssertTrue(app.buttons["continueMetering"].isHittable)
        app.buttons["continueMetering"].tap()
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        measure(app)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.staticTexts["第 2 张"].waitForExistence(timeout: 5))
    }

    func testManualRetainsSelectionAndCanReturnToLive() {
        let app = launch()
        selectExposure("M 手动", in: app)
        stepParameter(in: app)
        let aperture = hero("光圈", in: app)
        let before = aperture.label
        measure(app)
        XCTAssertEqual(aperture.label, before)
        XCTAssertTrue(app.buttons["useSuggestion"].exists)
        let viewport = element("meterScrollView", in: app).frame
        let delta = element("deltaValue", in: app)
        XCTAssertTrue(delta.isHittable, "M 模式首屏的偏移刻度必须可见")
        XCTAssertLessThanOrEqual(delta.frame.maxY, viewport.minY + 1, "偏移刻度固定在滚动区域外")
        for id in ["apertureParameter", "shutterParameter", "parameterDial", "modePicker", "compensationButton", "useSuggestion"] {
            let control = element(id, in: app)
            XCTAssertTrue(control.isHittable, "\(id)在 M 模式首屏必须可操作")
            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(control.frame), "\(id)必须完整可见，不允许滚动后才出现")
        }
        XCTAssertTrue(app.buttons["measureButton"].isHittable)
        XCTAssertTrue(app.buttons["recordButton"].isHittable)
        attach("24-M模式采用建议")
        app.buttons["useSuggestion"].tap()
        XCTAssertTrue(app.buttons["recordButton"].isEnabled)
        app.buttons["liveButton"].tap()
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        XCTAssertFalse(element("aeLockStatus", in: app).exists)
    }

    func testSettingsAndFilmSheet() {
        let app = launch()
        app.buttons["filmButton"].tap()
        XCTAssertTrue(app.navigationBars["胶卷"].waitForExistence(timeout: 5))
        let slide = app.buttons["反转片"]
        XCTAssertTrue(slide.exists)
        reveal(slide, in: app)
        slide.tap()
        XCTAssertTrue(slide.isSelected)
        let iso = element("filmISOValue", in: app)
        let before = iso.label
        reveal(app.buttons["increaseISO"], in: app)
        app.buttons["increaseISO"].tap()
        eventually("ISO拨盘应修改胶卷ISO") { iso.label != before }
        attach("25-胶卷与ISO拨盘")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["filmButton"].label.contains("反转片"))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        attach("03-设置")
    }

    func testCompensationIsVisibleAndCanReset() {
        let app = launch()
        measure(app)
        let shutter = element("automaticShutter", in: app)
        let neutralShutter = shutter.label
        selectCompensation(in: app)
        for _ in 0..<3 { stepParameter(in: app) }
        eventually("补偿应增加到一档") { app.buttons["compensationButton"].label.contains("+1.0") }
        XCTAssertNotEqual(shutter.label, neutralShutter)
        attach("08-曝光补偿")
        compensationAction("归零", in: app)
        eventually("归零应立即反映在胶囊") { app.buttons["compensationButton"].label.contains("±0.0") }
        XCTAssertEqual(shutter.label, neutralShutter)
        compensationAction("补偿说明", in: app)
        XCTAssertTrue(app.buttons["exposureDone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resetCompensation"].isEnabled)
        app.buttons["exposureDone"].tap()
    }

    func testAutomaticParameterAndRestoredShutterMode() {
        let app = launch()
        let dial = element("parameterDial", in: app)
        let before = dial.value as? String
        let automatic = element("automaticShutter", in: app)
        XCTAssertTrue(automatic.exists)
        automatic.tap()
        XCTAssertEqual(dial.value as? String, before, "自动项不能抢占当前拨盘")
        XCTAssertTrue(app.buttons["increaseParameter"].isEnabled)
        selectExposure("S 快门优先", in: app)
        XCTAssertTrue(element("automaticAperture", in: app).exists)
        stepParameter(in: app)
        let shutterBefore = hero("快门", in: app).label
        relaunchPreserving(app)
        XCTAssertTrue(app.buttons["modePicker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["modePicker"].label.contains("快门优先"))
        XCTAssertTrue(app.buttons["increaseParameter"].isEnabled)
        stepParameter(in: app)
        XCTAssertNotEqual(hero("快门", in: app).label, shutterBefore)
    }

    func testDarkAppearance() {
        let app = launch()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let appearance = app.buttons["appearancePicker"]
        appearance.tap()
        let light = app.buttons["浅色"]
        XCTAssertTrue(light.waitForExistence(timeout: 3))
        light.tap()
        eventually("外观选择应保留") { appearance.label.contains("浅色") || (appearance.value as? String)?.contains("浅色") == true }
        attach("29-浅色弹层")
        app.buttons["完成"].tap()
        measure(app)
        attach("09-主界面固定深色")
        app.buttons["filmButton"].tap()
        XCTAssertTrue(app.navigationBars["胶卷"].waitForExistence(timeout: 5))
        attach("10-浅色胶卷弹层")
    }

    func testLargeDeviationRequiresAcknowledgement() {
        let app = launch()
        selectExposure("M 手动", in: app)
        for _ in 0..<15 { stepParameter(in: app, increase: false) }
        measure(app)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["reviewExposureRisk"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveRecord"].isEnabled)
        XCTAssertFalse(app.buttons["shareRecord"].isEnabled, "未确认风险时顶部ShareLink必须禁用")
        app.buttons["reviewExposureRisk"].tap()
        let acknowledgement = app.switches["riskAcknowledgement"]
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 3))
        XCTAssertTrue(acknowledgement.isHittable)
        XCTAssertFalse(app.buttons["saveRecord"].isEnabled, "定位风险区不能自动确认")
        attach("04-曝光偏移确认")
        acknowledgement.tap()
        XCTAssertTrue(app.buttons["saveRecord"].isEnabled)
        XCTAssertTrue(app.buttons["shareRecord"].isEnabled)
        acknowledgement.tap()
        XCTAssertFalse(app.buttons["saveRecord"].isEnabled)
        XCTAssertFalse(app.buttons["shareRecord"].isEnabled)
    }

    func testFailedRemeasureClearsReference() {
        let app = launch(arguments: ["-ui-testing-fail-remeasure"])
        measure(app)
        app.buttons["measureButton"].tap()
        XCTAssertTrue(app.alerts["暂时无法测光"].waitForExistence(timeout: 5))
        app.alerts.buttons["知道了"].tap()
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        XCTAssertFalse(element("aeLockStatus", in: app).exists)
        attach("12-重测失败后返回取景")
        measure(app)
    }

    func testSaveFailureCanRetry() {
        let app = launch(arguments: ["-ui-testing-save-failure"])
        measure(app)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["saveRecord"].waitForExistence(timeout: 5))
        app.buttons["saveRecord"].tap()
        XCTAssertTrue(element("saveError", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photoSettingsButton"].exists)
        XCTAssertTrue(app.buttons["shareRecord"].isEnabled)
        XCTAssertEqual(app.buttons["saveRecord"].label, "重试保存")
        attach("13-保存失败可重试")
        app.buttons["saveRecord"].tap()
        allowPhotoAdditionIfPrompted()
        XCTAssertTrue(element("saveSuccess", in: app).waitForExistence(timeout: 30))
        app.buttons["continueMetering"].tap()
        measure(app)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.staticTexts["第 2 张"].waitForExistence(timeout: 5))
    }

    func testPhotoDenialKeepsShareAvailable() {
        let app = launch(arguments: ["-ui-testing-save-denied"])
        measure(app)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["saveRecord"].waitForExistence(timeout: 5))
        app.buttons["saveRecord"].tap()
        XCTAssertTrue(app.buttons["photoSettingsButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shareRecord"].isEnabled)
        XCTAssertTrue(app.buttons["saveRecord"].isEnabled)
        XCTAssertFalse(element("saveSuccess", in: app).exists)
        attach("14-相册权限恢复入口")
    }

    func testCameraHelpAtLargestTextSize() {
        let app = launch(arguments: ["-ui-testing-camera-placeholder", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertFalse(app.buttons["measureButton"].isEnabled)
        reveal(app.buttons["enableCamera"], in: app)
        XCTAssertTrue(app.buttons["enableCamera"].isHittable)
        reveal(app.buttons["demoModeButton"], in: app)
        XCTAssertTrue(app.buttons["demoModeButton"].isHittable)
        attach("11-大字号首次相机引导")
        app.buttons["demoModeButton"].tap()
        XCTAssertTrue(element("demoBadge", in: app).waitForExistence(timeout: 5))
        measure(app)
    }

    func testLensSwitchClearsReadingAndRecordsChoice() {
        let app = launch()
        measure(app)
        let tele = app.buttons["lens_demo-tele"]
        XCTAssertTrue(tele.isHittable)
        tele.tap()
        let toast = element("lensDetail", in: app)
        // waitForExistence first polls after one second, which can miss this 1.5s toast.
        XCTAssertTrue(toast.exists, "切换后应立即显示镜头说明")
        XCTAssertTrue(toast.label.contains("裁切"))
        // Capture after the 0.2s numeric transition; the 1.5s lens toast remains visible.
        Thread.sleep(forTimeInterval: 0.35)
        attach("16-焦段切换")
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        XCTAssertTrue(tele.isSelected)
        eventually("镜头说明应短暂出现后消失", timeout: 4) { !toast.exists }
        measure(app)
        app.buttons["recordButton"].tap()
        let lensRow = element("recordParameter_lens", in: app)
        XCTAssertTrue(lensRow.waitForExistence(timeout: 5))
        XCTAssertTrue(lensRow.label.contains("2×"))
    }

    func testMeteringModesAndPointChangeReading() {
        let app = launch()
        selectMetering("点测光", in: app)
        let canvas = element("viewfinder", in: app)
        // Use the bright sky/sun and dark foreground mountain across both viewport crops.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.24)).tap()
        XCTAssertTrue((app.buttons["spotPositionMenu"].value as? String)?.contains("横向 75%") == true)
        measure(app)
        let bright = element("viewfinderReading", in: app).label
        attach("17-点测光")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.60)).tap()
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        measure(app)
        XCTAssertNotEqual(element("viewfinderReading", in: app).label, bright)
        selectMetering("中央重点", in: app)
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        measure(app)
        attach("18-中央重点测光")
        selectMetering("矩阵测光", in: app)
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        measure(app)
        app.buttons["recordButton"].tap()
        let meteringRow = element("recordParameter_metering", in: app)
        XCTAssertTrue(meteringRow.waitForExistence(timeout: 5))
        XCTAssertTrue(meteringRow.label.contains("矩阵测光"))
    }

    func testAccessiblePointPresetsAndRestoredMetering() {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        selectMetering("点测光", in: app)
        app.buttons["spotPositionMenu"].tap()
        XCTAssertTrue(app.buttons["上方"].waitForExistence(timeout: 3))
        app.buttons["上方"].tap()
        XCTAssertTrue((app.buttons["spotPositionMenu"].value as? String)?.contains("纵向 25%") == true)
        attach("19-大字号测光方式")
        relaunchPreserving(app)
        XCTAssertTrue(app.buttons["meteringMenu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meteringMenu"].label.contains("点测光"))
        XCTAssertTrue((app.buttons["spotPositionMenu"].value as? String)?.contains("纵向 50%") == true)
    }

    func testParameterTapRevealsEditor() {
        let app = launch()
        let aperture = hero("光圈", in: app)
        XCTAssertTrue(aperture.isHittable)
        let before = aperture.label
        aperture.tap()
        let dial = element("parameterDial", in: app)
        reveal(dial, in: app)
        XCTAssertTrue(dial.isHittable)
        attach("20-点选参数直达拨盘")
        stepParameter(in: app)
        XCTAssertNotEqual(aperture.label, before)
        XCTAssertTrue(app.buttons["measureButton"].isHittable)
    }

    func testRestoredCompensationIsVisibleOnInstrument() {
        let app = launch()
        selectCompensation(in: app)
        for _ in 0..<3 { stepParameter(in: app) }
        relaunchPreserving(app)
        let compensation = app.buttons["compensationButton"]
        XCTAssertTrue(compensation.waitForExistence(timeout: 5))
        XCTAssertTrue(compensation.isHittable)
        XCTAssertTrue(compensation.label.contains("+1.0"))
        attach("21-恢复非零补偿")
        compensationAction("归零", in: app)
        eventually("恢复的补偿应可归零") { compensation.label.contains("±0.0") }
    }

    func testLockedSpotCanMoveUsingMenu() {
        let app = launch()
        selectMetering("点测光", in: app)
        measure(app)
        app.buttons["meteringMenu"].tap()
        let down = app.buttons["下方"]
        XCTAssertTrue(down.waitForExistence(timeout: 3))
        XCTAssertTrue(down.isHittable)
        attach("22-锁定后调整测光点")
        down.tap()
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        XCTAssertFalse(element("aeLockStatus", in: app).exists)
        XCTAssertTrue((app.buttons["spotPositionMenu"].value as? String)?.contains("纵向 75%") == true)
        measure(app)
        XCTAssertTrue(element("aeLockStatus", in: app).exists)
        app.buttons["recordButton"].tap()
        let pointRow = element("recordParameter_point", in: app)
        XCTAssertTrue(pointRow.waitForExistence(timeout: 5))
        XCTAssertTrue(pointRow.label.contains("75%"), "记录必须使用新点位；不同点位的亮度可以相同")
    }

    func testAccessibleLayout() {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["measureButton"].isHittable)
        measure(app)
        let dial = element("parameterDial", in: app)
        reveal(dial, in: app)
        XCTAssertTrue(dial.isHittable)
        XCTAssertTrue(app.buttons["increaseParameter"].isHittable)
        compensationAction("补偿说明", in: app)
        XCTAssertTrue(app.buttons["exposureDone"].waitForExistence(timeout: 5))
        reveal(app.buttons["resetCompensation"], in: app)
        XCTAssertTrue(app.buttons["resetCompensation"].isHittable)
        app.buttons["exposureDone"].tap()
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["saveRecord"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveRecord"].isHittable)
        XCTAssertTrue(app.buttons["shareRecord"].isHittable)
        let summary = element("recordParameterSummary", in: app)
        XCTAssertTrue(summary.exists)
        let apertureRow = element("recordParameter_aperture", in: app)
        reveal(apertureRow, in: app)
        XCTAssertTrue(element("recordParameter_iso", in: app).label.contains("400"))
        XCTAssertTrue(apertureRow.label.contains("f/5.6"))
        XCTAssertTrue(element("recordParameter_shutter", in: app).label.contains("快门"))
        attach("15-大字号记录参数")
        XCTAssertTrue(app.buttons["saveRecord"].isHittable)
        attach("07-大字号记录")
    }

    func testAccessibility3CompensationCanScrollAndActivate() {
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        measure(app)
        let delta = element("deltaValue", in: app)
        let fixedFrame = delta.frame
        let compensation = app.buttons["compensationButton"]
        reveal(compensation, in: app)
        let viewport = element("meterScrollView", in: app).frame
        XCTAssertTrue(compensation.isHittable)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(compensation.frame), "最后一个胶囊必须完整滚入底栏上方")
        XCTAssertEqual(delta.frame, fixedFrame, "滚动仪表不能移走偏移刻度")
        compensation.tap()
        XCTAssertTrue(compensation.isSelected)
        XCTAssertEqual(element("parameterDial", in: app).label, "曝光补偿")
        attach("06-大字号参数")
    }

    func testDialDragChangesApertureAndSnaps() {
        let app = launch()
        measure(app)
        let aperture = hero("光圈", in: app)
        aperture.tap()
        let dial = element("parameterDial", in: app)
        reveal(dial, in: app)
        let before = aperture.label
        let start = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.35))
        let end = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        start.press(forDuration: 0.08, thenDragTo: end)
        eventually("真实横拖拨盘必须修改参数", timeout: 5) { aperture.label != before }
        assertStableValue(dial)
        XCTAssertTrue(element("aeLockStatus", in: app).exists, "调参保留冻结测光基准")
        XCTAssertTrue(app.buttons["recordButton"].isEnabled)
        attach("26-拨盘拖动调光圈")
    }

    func testSpotDragClearsLockAndMovesPoint() {
        let app = launch()
        selectMetering("点测光", in: app)
        measure(app)
        let canvas = element("viewfinder", in: app)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.40))
        start.press(forDuration: 0.08, thenDragTo: end)
        eventually("拖动测光点应清除旧锁定") { !self.element("aeLockStatus", in: app).exists }
        XCTAssertFalse(app.buttons["recordButton"].isEnabled, "拖点不能自动测量")
        let point = app.buttons["spotPositionMenu"]
        let value = point.value as? String ?? ""
        let coordinates = value.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .compactMap { Double(String($0)) }
        XCTAssertEqual(coordinates.count, 2, "取样位置应提供横纵百分比：\(value)")
        guard coordinates.count == 2 else { return }
        // XCTest's final touch event can settle a few points before its requested endpoint.
        XCTAssertEqual(coordinates[0], 25, accuracy: 5, "横向应接近拖动目标：\(value)")
        XCTAssertEqual(coordinates[1], 40, accuracy: 5, "纵向应接近拖动目标：\(value)")
        XCTAssertGreaterThan(abs(coordinates[0] - 50), 15, "取样点应明显离开中心：\(value)")
        attach("27-点测光拖动后")
        measure(app)
        XCTAssertTrue(element("aeLockStatus", in: app).exists)
        attach("28-点测光拖动后锁定")
    }

    func testLockedStatusAndReturnToLive() {
        let app = launch()
        measure(app)
        let lock = element("aeLockStatus", in: app)
        XCTAssertTrue(lock.isHittable)
        XCTAssertLessThanOrEqual(lock.frame.height, 26, "AE-L 应是紧凑状态徽标，不是 44pt 控件外观")
        XCTAssertEqual(lock.frame.height, element("demoBadge", in: app).frame.height, accuracy: 2)
        XCTAssertFalse(app.buttons["aeLockStatus"].exists, "AE-L 只表示状态")
        app.buttons["liveButton"].tap()
        XCTAssertFalse(lock.exists)
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        XCTAssertTrue(element("automaticShutter", in: app).label.contains("—"))
        XCTAssertTrue(app.buttons["measureButton"].isEnabled)
        attach("30-AEL返回实时")
        measure(app)
    }

    func testCompactFirstScreenContainsMeterDialAndActions() {
        let app = launch()
        let canvas = element("viewfinder", in: app)
        let dial = element("parameterDial", in: app)
        XCTAssertTrue(canvas.exists)
        XCTAssertGreaterThan(canvas.frame.height, 120)
        XCTAssertGreaterThanOrEqual(canvas.frame.width, app.frame.width - 2)
        XCTAssertTrue(hero("光圈", in: app).isHittable)
        XCTAssertTrue(element("automaticShutter", in: app).isHittable)
        XCTAssertTrue(dial.isHittable, "SE首屏拨盘应无需滚动即可操作")
        XCTAssertTrue(app.buttons["measureButton"].isHittable)
        XCTAssertTrue(app.buttons["compensationButton"].isHittable)
        for id in ["measureButton", "recordButton", "filmButton", "settingsButton"] {
            let frame = app.buttons[id].frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(id)触控宽度")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(id)触控高度")
        }
        attach("31-完整首屏布局")
    }

    func testReducedTransparencyAndMotionRemainOperable() {
        let app = launch(arguments: ["-ui-testing-reduce-transparency", "-ui-testing-reduce-motion"])
        XCTAssertTrue(app.buttons["filmButton"].isHittable)
        XCTAssertTrue(app.buttons["meteringMenu"].isHittable)
        measure(app)
        attach("32-降低透明度锁定界面")
        stepParameter(in: app)
        selectMetering("点测光", in: app)
        app.buttons["spotPositionMenu"].tap()
        XCTAssertTrue(app.buttons["左侧"].waitForExistence(timeout: 3))
        app.buttons["左侧"].tap()
        measure(app)
        attach("33-减少动态点测光")
        app.buttons["liveButton"].tap()
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func hero(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[title == "光圈" ? "apertureParameter" : "shutterParameter"]
    }
    private func eventually(_ message: String, timeout: TimeInterval = 3, file: StaticString = #filePath,
                            line: UInt = #line, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message, file: file, line: line)
    }
    private func selectExposure(_ title: String, in app: XCUIApplication) {
        reveal(app.buttons["modePicker"], in: app)
        app.buttons["modePicker"].tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        eventually("曝光模式选择应生效") { app.buttons["modePicker"].label.contains(String(title.dropFirst(2))) }
    }
    private func selectMetering(_ title: String, in app: XCUIApplication) {
        app.buttons["meteringMenu"].tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        eventually("测光菜单选项应可操作") { option.isHittable }
        option.tap()
        eventually("测光方式选择应生效") { app.buttons["meteringMenu"].label.contains(title) }
    }
    private func selectCompensation(in app: XCUIApplication) {
        reveal(app.buttons["compensationButton"], in: app)
        app.buttons["compensationButton"].tap()
        XCTAssertTrue(element("parameterDial", in: app).exists)
    }
    private func compensationAction(_ title: String, in app: XCUIApplication) {
        let button = app.buttons["compensationButton"]
        reveal(button, in: app)
        button.press(forDuration: 1)
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        action.tap()
    }
    private func stepParameter(in app: XCUIApplication, increase: Bool = true) {
        let button = app.buttons[increase ? "increaseParameter" : "decreaseParameter"]
        reveal(button, in: app)
        XCTAssertTrue(button.isEnabled)
        button.tap()
    }
    private func measure(_ app: XCUIApplication) {
        eventually("测光按钮应在弹层完全收起后可操作", timeout: 5) {
            app.buttons["measureButton"].isEnabled && app.buttons["measureButton"].isHittable
        }
        app.buttons["measureButton"].tap()
        eventually("一次点击后应完成测光并启用记录", timeout: 8) { app.buttons["recordButton"].isEnabled }
    }
    private func relaunchPreserving(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-preserve"]
        app.launch()
        XCTAssertTrue(app.buttons["measureButton"].waitForExistence(timeout: 10))
    }
    private func assertStableValue(_ element: XCUIElement) {
        var previous = element.value as? String
        var unchangedSince = Date()
        eventually("拨盘释放后应吸附并稳定", timeout: 5) {
            let value = element.value as? String
            if value != previous { previous = value; unchangedSince = Date(); return false }
            return value != nil && Date().timeIntervalSince(unchangedSince) >= 0.5
        }
    }
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            // Never choose an arbitrary ScrollView: StopDial is horizontal.
            let identifiers = ["recordScrollView", "filmScrollView", "settingsForm", "cameraHelpScrollView", "meterScrollView"]
            let candidates = identifiers.map { element($0, in: app) }
            let targetMatch = NSPredicate(format: "identifier == %@ AND label == %@", target.identifier, target.label)
            let explicit = candidates.first {
                $0.exists && $0.isHittable && $0.descendants(matching: .any).matching(targetMatch).firstMatch.exists
            }
            let form = app.collectionViews.firstMatch
            let targetIsInForm = form.exists && form.isHittable && form.descendants(matching: .any).matching(targetMatch).firstMatch.exists
            let container = explicit ?? (targetIsInForm ? form : nil)
            let screen = app.windows.firstMatch.frame
            let viewport = (container?.frame ?? screen).intersection(screen)
            // isHittable may be true for controls clipped by a ScrollView or an overlay.
            if target.isHittable && viewport.insetBy(dx: -1, dy: -1).contains(target.frame) { return }
            guard let container else { break }
            let above = target.exists && target.frame.midY < container.frame.midY
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: above ? 0.30 : 0.82))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: above ? 0.82 : 0.30))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("目标控件应能在明确的纵向容器内完整显示：\(target.identifier)")
    }
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func allowPhotoAdditionIfPrompted() {
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if permission.waitForExistence(timeout: 8) {
            let allow = permission.buttons.matching(NSPredicate(format: "(label CONTAINS[c] 'Allow' OR label CONTAINS '允许' OR label CONTAINS '添加') AND NOT (label CONTAINS[c] 'Don' OR label CONTAINS '不允许')")).firstMatch
            XCTAssertTrue(allow.exists)
            allow.tap()
        }
    }
}
