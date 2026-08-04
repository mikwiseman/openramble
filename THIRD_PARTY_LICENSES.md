# Сторонние компоненты

Приложение раздаётся собранным образом, внутри которого едет чужой код и чужие
веса. Здесь перечислено всё, что в нём есть, и на каких условиях.

## Модель распознавания речи

**Parakeet TDT 0.6B v3**
© NVIDIA. Лицензия **CC BY 4.0** (https://creativecommons.org/licenses/by/4.0/).

Исходная модель: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3

**Изменения относительно оригинала** (требование раздела 3(a) лицензии CC BY):
модель сконвертирована в формат Core ML и энкодер квантизован 6-битной
палитризацией со смешанной точностью. Конвертация выполнена проектом
FluidInference, дистрибутив:
https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml

Сам дистрибутив FluidInference заявлен под Apache 2.0; на веса это условий
CC BY 4.0 не отменяет, поэтому атрибуция NVIDIA обязательна и приводится выше.

Приложение скачивает конкретную ревизию `aed02740059203c4a87495924f685de3722ae9ce`,
берёт из неё 21 файл общим весом 483 105 645 байт и проверяет SHA-256 каждого.
Веса в репозиторий Wai Dictation не входят и в образ приложения не вкомпилированы —
их скачивает пользователь по кнопке.

**Parakeet TDT-CTC 110M** (акустический подсказчик терминов)
© NVIDIA. Лицензия **CC BY 4.0** (https://creativecommons.org/licenses/by/4.0/).

Исходная модель: https://huggingface.co/nvidia/parakeet-tdt_ctc-110m

**Изменения относительно оригинала** (требование раздела 3(a) лицензии CC BY):
модель сконвертирована в формат Core ML со смешанной точностью. Конвертация
выполнена проектом FluidInference, дистрибутив:
https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml

Приложение скачивает конкретную ревизию `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`,
берёт из неё 16 файлов общим весом 102 803 869 байт и проверяет SHA-256 каждого.

Эта же атрибуция продублирована в приложении: Настройки → О программе.

## Библиотеки внутри приложения

| Компонент | Версия | Лицензия | Назначение |
|---|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.5 | Apache 2.0 | Запуск Parakeet через Core ML |
| [Sparkle](https://sparkle-project.org) | 2.9.4 | MIT | Обновления приложения |

Обе зависимости зафиксированы immutable commit SHA соответствующих тегов:
FluidAudio 0.15.5 — `19600a485baa4998812e4654b70d2bab8f2c9949`,
Sparkle 2.9.4 — `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`.

### Sparkle

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.
```

Лицензия MIT; полный upstream-файл `LICENSE`, включая external notices,
включается в DMG как `Sparkle-LICENSE.txt`.

### FluidAudio

Лицензия Apache 2.0; полный upstream-файл включается в DMG как
`FluidAudio-Apache-2.0.txt`.

FluidAudio поставляется одной библиотекой, и вместе с ней в образ попадает
код, который она включает в себя:

- **fastcluster** — © 2011 Daniel Müllner; изменения с версии 1.1.24 © Google Inc.
  Лицензия BSD (2 пункта), полный текст в `FluidAudio-fastcluster-BSD.txt`.
- **VBx** — © 2021–2024 BUT Speech@FIT. Лицензия Apache 2.0, полный текст в
  `FluidAudio-vbx-Apache-2.0.txt`.

Ни то, ни другое Wai Dictation не использует — это части разделения дикторов,
которое нам не нужно. Но код едет в образе, поэтому упомянут здесь.

## Что не покрыто

Название «Wai Dictation» и иконка приложения под лицензию исходного кода
не подпадают.
