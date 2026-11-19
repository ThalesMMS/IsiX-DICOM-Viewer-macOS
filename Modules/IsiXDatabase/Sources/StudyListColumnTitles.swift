//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The header each column of the study list had, in every language of the
/// application, while the columns shown were saved by the title of their
/// header.
///
/// That preference held the title in the language of the day, so one saved in
/// German names "Befund" and "Sperren" where the Spanish list has "Informe"
/// and "Bloquear". The columns are saved by their identifier now, and a
/// preference saved before is read through these titles, whatever the
/// language the list is shown in. A title a language gives a header later
/// needs no entry here: nothing is saved under it.
///
/// Two columns shared a title in two languages, the comments and the note in
/// Korean and in Simplified Chinese. A preference saved there has one state
/// for both, which was applied to the first of them in the list, and is read
/// so still.
public enum StudyListColumnTitles {
    /// The titles of each column, by its identifier.
    public static let former: [String: Set<String>] = [
        "name": ["Nom du patient", "Nombre del paciente", "Nome del paziente", "Nome do paciente", "Patient name", "Patientenname", "Имя пациента",
                 "اسم المريض", "रोगी का नाम", "患者名", "患者姓名", "환자 이름"],
        "reportURL": ["Befund", "Compte rendu", "Informe", "Laudo", "Referto", "Report", "Заключение", "Отчёт", "تقرير", "रिपोर्ट", "レポート", "报告",
                      "보고서"],
        "lockedStudy": ["Blocca", "Bloquear", "Lock", "Sperren", "Verrouiller", "Блокировка", "Замок", "قفل", "ताला", "ロック", "锁定", "기타 제품", "잠금"],
        "patientID": ["ID del paciente", "ID do paciente", "ID du patient", "ID paziente", "ID пациента", "Patient ID", "Patienten-ID",
                      "معرف المريض", "रोगी ID", "患者 ID", "환자 ID"],
        "yearOld": ["Age", "Alter", "Edad", "Età", "Idade", "Âge", "Возраст", "العمر", "आयु", "年齢", "年龄", "나이"],
        "accessionNumber": ["Accession Number", "Numero di accettazione", "Numéro d’accès", "Número de acceso", "Número de acesso", "Zugangsnummer",
                            "Инвентарный номер", "Регистрационный номер", "رقم الفحص", "प्रवेश संख्या", "受付番号", "检查申请号", "접수 번호"],
        "studyName": ["Descripción del estudio", "Description de l’examen", "Descrizione studio", "Descrição do estudo", "Studienbeschreibung",
                      "Study Description", "Описание исследования", "وصف الدراسة", "अध्ययन विवरण", "检查描述", "検査記述", "검사 설명"],
        "modality": ["Modalidad", "Modalidade", "Modality", "Modalità", "Modalität", "Modalité", "Модальность", "نوع التصوير", "मोडैलिटी", "साधन",
                     "モダリティ", "影像模态", "검사 유형"],
        "id": ["ID", "المعرّف", "पहचान"],
        "comment": ["Comentarios", "Comentários", "Commentaires", "Commenti", "Comments", "Kommentare", "Комментарий", "تعليقات", "टिप्पणियाँ",
                    "コメント", "备注", "메모"],
        "stateText": ["Estado", "Stato", "Status", "Statut", "Статус", "الحالة", "स्थिति", "状态", "状態", "상태"],
        "date": ["Aufnahmedatum", "Data de aquisição", "Data di acquisizione", "Date Acquired", "Date d’acquisition", "Fecha de adquisición",
                 "Дата приобретения", "Дата съёмки", "تاريخ التقاط الصور", "अधिग्रहण की तिथि", "取得日", "采集日期", "날짜 취득", "취득 날짜"],
        "noFiles": ["# im", "# चित्र", "# मैं हूँ", "N. imm.", "N.º im.", "عدد الصور", "画像数"],
        "noSeries": ["# Serien", "# series", "# séries", "# серий", "# серия", "# शृंखला", "# 序列", "# 시리즈", "#série", "Anzahl der Serien",
                     "N. serie", "N.º series", "عدد السلاسل", "シリーズ数"],
        "dateAdded": ["Data adicionada", "Data aggiunta", "Data de adição", "Date Added", "Date d'ajout", "Fecha de incorporación", "Hinzugefügt am",
                      "Дата добавлена", "Дата добавления", "تاريخ الإضافة", "तिथि जोड़ी", "添加日期", "追加日", "날짜 추가", "추가 날짜"],
        "dateOpened": ["Data de abertura", "Data di apertura", "Date Opened", "Date d’ouverture", "Fecha de apertura", "Geöffnet am",
                       "Дата открытия", "تاريخ الفتح", "खुलने की तिथि", "已打开日期", "開いた日", "열어 본 날짜", "영업시간"],
        "referringPhysician": ["Medico referente", "Medific Referente", "Médecin prescripteur", "Médico de referência", "Médico solicitante",
                               "Referring Physician", "Überweisender Arzt", "Направивший врач", "Ссылаясь на врача", "الطبيب المُحيل",
                               "संदर्भित चिकित्सक", "参考哲学", "紹介医", "转诊医师", "의뢰 의사"],
        "performingPhysician": ["Durchführender Arzt", "Medico eseguente", "Médecin exécutant", "Médecin réalisant l’examen", "Médico Realizador",
                                "Médico responsable", "Performing Physician", "Выполняющий врач", "الطبيب المنفّذ", "प्रदर्शन कर रहे चिकित्सक",
                                "実施医", "检查医师", "表演哲学博士", "검사 의사"],
        "institutionName": ["Einrichtung", "Institución", "Instituição", "Institution", "Istituto", "Établissement", "Учреждение", "институт",
                            "المؤسسة", "संस्था", "施設", "机构", "기관"],
        "albumsNames": ["Alben", "Album", "Albums", "Álbumes", "Álbuns", "Альбомы", "الألبومات", "एलबम", "アルバム", "相簿", "앨범"],
        "dateOfBirth": ["Data de Nascimento", "Data di nascita", "Date de naissance", "Date of Birth", "Fecha de nacimiento", "Geburtsdatum",
                        "Дата рождения", "تاريخ الميلاد", "जन्मतिथि", "出生日期", "生年月日", "생년월일"],
        "localstring": ["∆"],
        "comment2": ["Comentarios 2", "Comentários 2", "Comment. 2", "Commentaires 2", "Commenti 2", "Comments 2", "Kommentare 2", "Коммент. 2",
                     "Комментарии 2", "تعليقات 2", "टिप्पणियाँ 2", "コメント 2", "备注 2", "댓글 2"],
        "comment3": ["Comentarios 3", "Comentários 3", "Comment. 3", "Commentaires 3", "Commenti 3", "Comments 3", "Kommentare 3", "Коммент. 3",
                     "Комментарии 3", "تعليقات 3", "टिप्पणियाँ 3", "コメント 3", "备注 3", "댓글 3"],
        "comment4": ["Comentarios 4", "Comentários 4", "Comment. 4", "Commentaires 4", "Commenti 4", "Comments 4", "Kommentare 4", "Коммент. 4",
                     "Комментарии 4", "تعليقات 4", "टिप्पणियाँ 4", "コメント 4", "备注 4", "댓글 4"],
        "note": ["Nota", "Note", "Notiz", "Remarque", "Замечание", "ملاحظة", "टिप्पणी", "メモ", "备注", "메모", "이름 *"],
    ]

    /// Whether `title` was the header of the column `identifier` in some
    /// language.
    public static func names(_ title: String, column identifier: String) -> Bool {
        former[identifier]?.contains(title) ?? false
    }
}
