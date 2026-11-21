/*****************************************************************************
 *
 * This MobilityDB code is provided under The PostgreSQL License.
 * Copyright (c) 2016-2026, Université libre de Bruxelles and MobilityDB
 * contributors
 *
 * MobilityDB includes portions of PostGIS version 3 source code released
 * under the GNU General Public License (GPLv2 or later).
 * Copyright (c) 2001-2026, PostGIS contributors
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation for any purpose, without fee, and without a written
 * agreement is hereby granted, provided that the above copyright notice and
 * this paragraph and the following two paragraphs appear in all copies.
 *
 * IN NO EVENT SHALL UNIVERSITE LIBRE DE BRUXELLES BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING
 * LOST PROFITS, ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION,
 * EVEN IF UNIVERSITE LIBRE DE BRUXELLES HAS BEEN ADVISED OF THE POSSIBILITY
 * OF SUCH DAMAGE.
 *
 * UNIVERSITE LIBRE DE BRUXELLES SPECIFICALLY DISCLAIMS ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON
 * AN "AS IS" BASIS, AND UNIVERSITE LIBRE DE BRUXELLES HAS NO OBLIGATIONS TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 *
 *****************************************************************************/

#pragma once

#include "duckdb.hpp"
#include "duckdb/common/string_util.hpp"
#include "meos_wrapper_simple.hpp"

#include <cstring>

namespace duckdb {

//! The MEOS type of an indexed column, read from MEOS by the canonical name its alias carries
//! (meostype_from_string), T_UNKNOWN for a type MEOS does not define.
inline MeosType IndexColumnMeosType(const LogicalType &type) {
	return meostype_from_string(StringUtil::Lower(type.GetAlias()).c_str());
}

//! An STBox key stores no SRID, so that boxes of one column and a query compare as the index
//! stores them; a box with no spatial dimension carries none to clear.
inline void IndexKeyClearSrid(STBox *box) {
	if (MEOS_FLAGS_GET_X(box->flags) && box->srid != 0) {
		box->srid = 0;
	}
}

//! Write into `key` the box a TRTREE or TSPTREE index stores for one value of column type
//! `coltype`, as type_bboxtype states it and PostgreSQL's GiST and SP-GiST classes
//! store it: the value itself for a box type, the span the bounds of a number or time set and
//! of a span set state, and the box a spatial set or a temporal value stores. `data` and
//! `size` are the bytes of the value; `key` holds `keysize` bytes, the size of the key type.
//! False when the bytes are not a value of the column's type.
inline bool IndexValueKey(MeosType coltype, MeosType keytype, size_t keysize, const uint8_t *data,
                          size_t size, void *key) {
	memset(key, 0, keysize);
	if (coltype == keytype) {
		if (size != keysize) {
			return false;
		}
		memcpy(key, data, keysize);
	} else if (set_spantype(coltype)) {
		set_set_span(reinterpret_cast<const Set *>(data), static_cast<Span *>(key));
	} else if (spanset_type(coltype)) {
		memcpy(key, &reinterpret_cast<const SpanSet *>(data)->span, sizeof(Span));
	} else if (set_type(coltype)) {
		spatialset_set_stbox(reinterpret_cast<const Set *>(data), static_cast<STBox *>(key));
	} else if (temporal_type(coltype)) {
		temporal_set_bbox(reinterpret_cast<const Temporal *>(data), key);
	} else {
		return false;
	}
	if (keytype == T_STBOX) {
		IndexKeyClearSrid(static_cast<STBox *>(key));
	}
	return true;
}

//! True when the key of a column bounds its values rather than answering its predicates: the
//! operators of a set and of a span set compare elements, and their key is the extent of those
//! elements, so a candidate the index returns is rechecked against the predicate itself, as
//! PostgreSQL rechecks the GiST and SP-GiST classes of the sets.
inline bool IndexKeyIsLossy(MeosType coltype) {
	return set_type(coltype) || spanset_type(coltype);
}

//! The key of the query operand of an indexed predicate, computed as the key of a row is
//! (IndexValueKey) from the MEOS type of the operand's own type, into a buffer the caller frees.
//! Null when the operand has no key of the index's key type: the predicate then stays a filter
//! and the scan answers it, so a value of another kind is never read as a box.
inline void *IndexQueryKey(const LogicalType &type, MeosType keytype, size_t keysize,
                           const uint8_t *data, size_t size) {
	MeosType querytype = IndexColumnMeosType(type);
	if (querytype == T_UNKNOWN || type_bboxtype(querytype) != keytype) {
		return nullptr;
	}
	void *key = malloc(keysize);
	if (key && !IndexValueKey(querytype, keytype, keysize, data, size, key)) {
		free(key);
		return nullptr;
	}
	return key;
}

} // namespace duckdb
