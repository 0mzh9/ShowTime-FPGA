"""Card layout for calibration; no camera, serial or calibration mathematics."""
from PySide6.QtCore import Qt,QSize
from PySide6.QtGui import QColor,QPainter,QPalette,QPixmap
from PySide6.QtWidgets import (QAbstractItemView,QDoubleSpinBox,QFrame,QGridLayout,QHBoxLayout,
    QHeaderView,QLabel,QLineEdit,QPushButton,QSizePolicy,QSpinBox,QStyleFactory,QTableWidget,QVBoxLayout,QWidget)
from calibration_dialog_base import ImageList
from shiboken6 import isValid

STYLE="""
QWidget#calibrationPage {background:#f3f6fa; color:#213547;}
QWidget#calibrationPage QWidget {color:#213547; background:transparent;}
QWidget#calibrationPage QFrame#calCard {background:#ffffff; border:1px solid #dce5ec; border-radius:12px;}
QWidget#calibrationPage QLabel#calTitle {font-size:21px; font-weight:600; color:#15384b;}
QWidget#calibrationPage QLabel#calSection {font-size:15px; font-weight:600; color:#173e4c;}
QWidget#calibrationPage QLabel#calMuted {color:#60758a; font-size:12px;}
QWidget#calibrationPage QLabel#calField {color:#526a7e; font-size:12px;}
QWidget#calibrationPage QLabel#calBadge {background:#e5f4ef; color:#176d60; border-radius:9px; padding:5px 10px; font-size:12px;}
QWidget#calibrationPage QLabel#calSummary {color:#176d60; font-size:12px;}
QWidget#calibrationPage QFrame#calCurrentBox {background:#f0f7f5; border:1px solid #dbeae4; border-radius:8px;}
QWidget#calibrationPage QLabel#calCurrent {color:#476c62; font-size:11px;}
QWidget#calibrationPage QLabel#calStatus {color:#536d80; font-size:12px;}
QWidget#calibrationPage QLineEdit,
QWidget#calibrationPage QAbstractSpinBox {
    background:#f8fafc; color:#172f42; border:1px solid #d3dfe8;
    border-radius:6px; padding:6px 8px; min-height:18px;
    selection-background-color:#d9eee8; selection-color:#133a33;
}
QWidget#calibrationPage QAbstractSpinBox QLineEdit {border:0; padding:0; background:transparent;}
QWidget#calibrationPage QLineEdit:focus,
QWidget#calibrationPage QAbstractSpinBox:focus {background:#ffffff; border-color:#36998c;}
QWidget#calibrationPage QPushButton {
    background:#ffffff; color:#36576b; border:1px solid #cfdce5;
    border-radius:7px; padding:7px 12px; min-height:18px;
}
QWidget#calibrationPage QPushButton:hover {background:#eef7f5; border-color:#89bfb5;}
QWidget#calibrationPage QPushButton:pressed {background:#dcefe9;}
QWidget#calibrationPage QPushButton#calPrimary {background:#178579; color:#ffffff; border-color:#178579; font-weight:600;}
QWidget#calibrationPage QPushButton#calPrimary:hover {background:#116f65; border-color:#116f65;}
QWidget#calibrationPage QPushButton#calSoft {background:#eaf5f1; color:#176d60; border-color:#c7e4da;}
QWidget#calibrationPage QPushButton#calLink {background:transparent; border:0; color:#60758a; padding:5px 7px;}
QWidget#calibrationPage QPushButton:disabled,
QWidget#calibrationPage QPushButton#calPrimary:disabled {background:#edf2f5; color:#687d8e; border-color:#dde5eb;}
QWidget#calibrationPage QLineEdit:disabled,
QWidget#calibrationPage QAbstractSpinBox:disabled {background:#f5f8fa; color:#718393; border-color:#dfe7ed;}
QWidget#calibrationPage QListWidget {background:#f8fbfd; color:#304c60; border:1px dashed #b9cedd; border-radius:8px; padding:5px;}
QWidget#calibrationPage QListWidget::item {padding:4px 6px; border-radius:4px;}
QWidget#calibrationPage QTableWidget {background:#ffffff; color:#304c60; border:0; gridline-color:#e7edf2; alternate-background-color:#f7fafc;}
QWidget#calibrationPage QAbstractItemView::item:selected {background:#deeee8; color:#173d33;}
QWidget#calibrationPage QHeaderView::section {background:#eef4f7; color:#516b7e; border:0; border-bottom:1px solid #dce6ed; padding:7px 6px; font-weight:600;}
QWidget#calibrationPage QTableCornerButton::section {background:#eef4f7; border:0;}
QWidget#calibrationPage QLabel#calPreview {background:#f3f7fa; color:#5d7486; border:1px solid #e0e9ef; border-radius:7px;}
QWidget#calibrationPage QScrollBar:vertical {background:#f3f6fa; width:10px; margin:0;}
QWidget#calibrationPage QScrollBar::handle:vertical {background:#c1ced8; min-height:24px; border-radius:4px;}
QWidget#calibrationPage QScrollBar::add-line:vertical,
QWidget#calibrationPage QScrollBar::sub-line:vertical {height:0;}
QWidget#calibrationPage QScrollBar::add-page:vertical,
QWidget#calibrationPage QScrollBar::sub-page:vertical {background:transparent;}
"""

class ImageDropList(ImageList):
    def paintEvent(self,event):
        super().paintEvent(event)
        if not self.count():
            p=QPainter(self.viewport());p.setPen(QColor('#60758a'))
            p.drawText(self.viewport().rect().adjusted(12,4,-12,-4),Qt.AlignmentFlag.AlignCenter,
                '拖入棋盘格原图或采集文件夹\n支持多选 · 仅使用 1280 × 720 原图')

class ResultTable(QTableWidget):
    def sizeHint(self):return QSize(480,150)
    def paintEvent(self,event):
        super().paintEvent(event)
        if not self.rowCount():
            p=QPainter(self.viewport());p.setPen(QColor('#60758a'))
            p.drawText(self.viewport().rect(),Qt.AlignmentFlag.AlignCenter,
                       '尚无标定结果\n生成后查看图片筛选与重投影误差')

class PreviewLabel(QLabel):
    def __init__(self,text):
        super().__init__(text);self.source=QPixmap();self.setObjectName('calPreview')
        self.setAlignment(Qt.AlignmentFlag.AlignCenter);self.setMinimumSize(100,122)
        self.setSizePolicy(QSizePolicy.Policy.Ignored,QSizePolicy.Policy.Expanding)
    def setPixmap(self,pixmap):
        self.source=QPixmap(pixmap)
        if self.source.isNull():super().setPixmap(QPixmap())
        else:self._scale()
    def _scale(self):
        if not self.source.isNull():super().setPixmap(self.source.scaled(self.contentsRect().adjusted(6,6,-6,-6).size(),Qt.AspectRatioMode.KeepAspectRatio,Qt.TransformationMode.SmoothTransformation))
    def setText(self,text):
        self.source=QPixmap();super().setText(text)
    def resizeEvent(self,event):super().resizeEvent(event);self._scale()

def set_preview(widget,path,empty):
    if path is None:widget.setText(empty);return
    pixmap=QPixmap(str(path))
    if pixmap.isNull():widget.setText('图片无法预览')
    else:widget.setPixmap(pixmap)

def label(text,name='calMuted'):
    result=QLabel(text);result.setObjectName(name)
    result.setSizePolicy(QSizePolicy.Policy.Preferred,QSizePolicy.Policy.Fixed)
    return result

def card(title):
    frame=QFrame();frame.setObjectName('calCard')
    layout=QVBoxLayout(frame);layout.setContentsMargins(16,13,16,14);layout.setSpacing(10)
    heading=QHBoxLayout();heading.addWidget(label(title,'calSection'));heading.addStretch()
    layout.addLayout(heading)
    return frame,layout,heading

def button(text,slot,name=''):
    result=QPushButton(text);result.clicked.connect(slot)
    if name:result.setObjectName(name)
    return result

def build_ui(page):
    page.setObjectName('calibrationPage');page.setAttribute(Qt.WidgetAttribute.WA_StyledBackground,True)
    page.setAutoFillBackground(True)
    palette=page.palette()
    for role,color in [(QPalette.Window,'#f3f6fa'),(QPalette.Base,'#ffffff'),(QPalette.AlternateBase,'#f7fafc'),
        (QPalette.WindowText,'#213547'),(QPalette.Text,'#213547'),(QPalette.Button,'#ffffff'),
        (QPalette.ButtonText,'#36576b'),(QPalette.PlaceholderText,'#7d90a1'),
        (QPalette.Highlight,'#deeee8'),(QPalette.HighlightedText,'#173d33')]:palette.setColor(role,QColor(color))
    page.setPalette(palette);page.setStyleSheet(STYLE)
    main=QVBoxLayout(page);main.setContentsMargins(2,4,2,2);main.setSpacing(12)
    intro=QHBoxLayout();titles=QVBoxLayout();titles.setSpacing(4)
    titles.addWidget(label('镜头标定与矫正系数','calTitle'))
    titles.addWidget(label('导入棋盘格自动标定，或填写镜头参数；验证通过后写入 FPGA。'))
    intro.addLayout(titles,1);intro.addWidget(label('Brown4 模型','calBadge'));intro.addWidget(label('1280 × 720','calBadge'))
    main.addLayout(intro)
    top=QHBoxLayout();top.setSpacing(12);main.addLayout(top)

    pictures,pictures_layout,pictures_heading=card('01  标定图片')
    page.image_count=label('0 张','calSummary');pictures_heading.addWidget(page.image_count)
    for text,slot,name in [('添加图片',page._select_files,''),('添加目录',page._select_folder,''),
                           ('移除',page._remove_selected,'calLink'),('清空',page._clear,'calLink')]:
        pictures_heading.addWidget(button(text,slot,name))
    page.images=ImageDropList();page.images.paths_dropped.connect(page.add_paths)
    page.images.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
    page.images.setTextElideMode(Qt.TextElideMode.ElideMiddle)
    page.images.setMinimumHeight(96);page.images.setMaximumHeight(116);pictures_layout.addWidget(page.images,1)
    def update_count(*_):
        if isValid(page.images) and isValid(page.image_count):page.image_count.setText(f'{page.images.count()} 张')
    page.images.model().rowsInserted.connect(update_count)
    page.images.model().rowsRemoved.connect(update_count)
    page.images.model().modelReset.connect(update_count)
    geometry=QHBoxLayout();geometry.setSpacing(10)
    page.cols=QSpinBox();page.cols.setRange(3,30);page.cols.setValue(11)
    page.rows=QSpinBox();page.rows.setRange(3,30);page.rows.setValue(8)
    page.square=QDoubleSpinBox();page.square.setRange(.01,10000);page.square.setDecimals(3);page.square.setValue(15);page.square.setSuffix(' mm')
    page.control_style=QStyleFactory.create('Fusion');page.control_style.setParent(page)
    for control in (page.cols,page.rows,page.square):control.setStyle(page.control_style)
    for title,widget in [('内角点列数',page.cols),('内角点行数',page.rows),('方格边长',page.square)]:
        group=QVBoxLayout();group.setSpacing(4);group.addWidget(label(title,'calField'));group.addWidget(widget);geometry.addLayout(group,1)
    page.run_button=button('检测并生成系数',page.start_calibration,'calPrimary')
    geometry.addWidget(page.run_button,0,Qt.AlignmentFlag.AlignBottom)
    pictures_layout.addLayout(geometry)
    pictures_layout.addWidget(label('内角点数为交点数；采集目录中优先读取 original_left.png。'))
    top.addWidget(pictures,1)

    page.editor,parameter_layout,parameter_heading=card('02  镜头参数')
    parameter_heading.addWidget(label('自动生成 / 手动输入','calBadge'))
    grid=QGridLayout();grid.setHorizontalSpacing(10);grid.setVerticalSpacing(5);page.fields={}
    for i,name in enumerate(('fx','fy','cx','cy','k1','k2','p1','p2')):
        column=i%4;row=(i//4)*2
        grid.addWidget(label(name+(' · px' if i<4 else ''),'calField'),row,column)
        edit=QLineEdit();edit.setMinimumWidth(0);edit.setPlaceholderText(name)
        edit.textChanged.connect(page._edited);page.fields[name]=edit;grid.addWidget(edit,row+1,column);grid.setColumnStretch(column,1)
    parameter_layout.addLayout(grid)
    actions=QHBoxLayout();actions.setSpacing(8)
    actions.addWidget(button('从 FPGA 当前参数填入',page.load_current))
    page.manual_button=button('验证手动参数',page.validate_manual,'calSoft');actions.addWidget(page.manual_button)
    current_toggle=QPushButton('查看当前系数');current_toggle.setObjectName('calLink');actions.addWidget(current_toggle)
    actions.addStretch();parameter_layout.addLayout(actions)
    page.coefficient_status=label('等待生成或验证参数。');page.coefficient_status.setWordWrap(True);parameter_layout.addWidget(page.coefficient_status)
    current=QFrame();current.setObjectName('calCurrentBox');current_layout=QVBoxLayout(current);current_layout.setContentsMargins(10,7,10,7)
    page.active_parameters=label('FPGA 当前参数：尚未读取','calCurrent');page.active_parameters.setWordWrap(True)
    current_layout.addWidget(page.active_parameters);parameter_layout.addWidget(current)
    current.hide()
    def toggle_current():
        show=current.isHidden();current.setVisible(show);current_toggle.setText('收起当前系数' if show else '查看当前系数')
    current_toggle.clicked.connect(toggle_current)
    page.editor.setToolTip('普通 Brown4 模型：k1 / k2 / p1 / p2，不能混用鱼眼模型的 k3 / k4。')
    parameter_layout.addStretch(1)
    page.active_fixed=None;top.addWidget(page.editor,1)

    lower=QHBoxLayout();lower.setSpacing(12);main.addLayout(lower,1)
    quality,quality_layout,quality_heading=card('03  筛选与质量')
    page.result_summary=label('等待标定结果','calSummary');quality_heading.addWidget(page.result_summary)
    page.table=ResultTable(0,4);page.table.setHorizontalHeaderLabels(('图片','筛选','原因','RMS / px'))
    page.table.setMinimumHeight(138);page.table.setAlternatingRowColors(True);page.table.setShowGrid(False)
    page.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
    page.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
    header=page.table.horizontalHeader();header.setStretchLastSection(False)
    for column in (0,2):header.setSectionResizeMode(column,QHeaderView.ResizeMode.Stretch)
    for column,width in [(1,65),(3,82)]:header.setSectionResizeMode(column,QHeaderView.ResizeMode.Fixed);header.resizeSection(column,width)
    page.table.verticalHeader().setVisible(False);page.table.verticalHeader().setDefaultSectionSize(29)
    page.table.itemSelectionChanged.connect(page._preview_selection);quality_layout.addWidget(page.table,1)
    lower.addWidget(quality,1)

    previews,preview_layout,preview_heading=card('图像预览')
    preview_heading.addWidget(label('离线标定预览','calBadge'))
    row=QHBoxLayout();row.setSpacing(10)
    for attr,title in [('original_preview','原始图像'),('corrected_preview','矫正预览')]:
        group=QVBoxLayout();group.setSpacing(5);group.addWidget(label(title,'calField'))
        panel=PreviewLabel('选择结果条目以预览' if attr=='original_preview' else '生成系数后查看效果')
        setattr(page,attr,panel);group.addWidget(panel,1);row.addLayout(group,1)
    preview_layout.addLayout(row,1);lower.addWidget(previews,1)

    footer=QFrame();footer.setObjectName('calCard');foot=QHBoxLayout(footer);foot.setContentsMargins(14,10,14,10)
    info=QVBoxLayout();info.setSpacing(4)
    page.status=label('等待导入棋盘格原图，或填写并验证镜头参数。','calStatus');page.status.setWordWrap(True)
    info.addWidget(page.status);info.addWidget(label('生成与验证不停止 FPGA；写入时暂停视频，保存完成后恢复。'))
    foot.addLayout(info,1)
    page.upload_button=button('写入 FPGA 并保存',page._request_upload,'calPrimary');page.upload_button.setEnabled(False)
    foot.addWidget(page.upload_button);main.addWidget(footer);page.commit_footer=footer
