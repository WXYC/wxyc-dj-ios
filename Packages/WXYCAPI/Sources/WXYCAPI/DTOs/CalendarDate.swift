//
//  CalendarDate.swift
//  WXYCAPI
//
//  Re-exports the generated calendar-day type under this package's own name, so
//  no consumer has to name WXYCAPIModels to spell a date-only value.
//
//  Created by Jake on 08/26/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

// Targeted import, matching TrackMatchHint.swift / SignInResponse.swift rather
// than a blanket `import WXYCAPIModels`. Since the 1.47.0 contract advance that
// module declares five names WXYCAPI also declares (EmailSignInRequest,
// LookupEmailRequest/Response, SendLoginCodeRequest, OTPSignInRequest), and a
// same-module declaration shadows an imported one *silently* -- see issue #129.
// Naming the single type keeps those out of scope entirely.
//
// This is the ONE place that names WXYCAPIModels for this type. It used to be
// repeated in eleven files -- four package sources, six package tests, and one
// app test -- which made the mitigation above eleven things to remember rather
// than one, and put that last one on the wrong side of the app-layer rule.
import struct WXYCAPIModels.CalendarDate

/// A date-only value: `(year, month, day)` and nothing else.
///
/// Generated from api.yaml's `format: date` mapping (`typeMappings:
/// date=CalendarDate`), and aliased here for the same reason
/// ``TrackMatchHint`` is: **app-layer code must never import `WXYCAPIModels`**
/// (see the repo's `CLAUDE.md`), and until this alias existed, naming a
/// `CalendarDate` outside the package forced exactly that import — which
/// ``CatalogRow``'s public initializer made unavoidable for anyone constructing
/// a row, `WXYCDJTests` included.
///
/// Why the type is date-only rather than a `Foundation.Date`: a `Date` is a
/// point on the UTC timeline, so decoding a bare `YYYY-MM-DD` into one
/// fabricates a time-of-day and a UTC anchor the value never had, shifting the
/// rendered day back by one on every host west of UTC. Comparison is a total
/// order over the three components and never consults `Calendar`/`TimeZone`,
/// which is the property ``RotationPredicate``'s expiry compare needs and the
/// one a zero-padded `"YYYY-MM-DD"` string used to stand in for (issue #79).
public typealias CalendarDate = WXYCAPIModels.CalendarDate
