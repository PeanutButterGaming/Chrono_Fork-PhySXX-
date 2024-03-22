// =============================================================================
// PROJECT CHRONO - http://projectchrono.org
//
// Copyright (c) 2014 projectchrono.org
// All rights reserved.
//
// Use of this source code is governed by a BSD-style license that can be found
// in the LICENSE file at the top level of the distribution and at
// http://projectchrono.org/license-chrono.txt.
//
// =============================================================================
// Authors: Alessandro Tasora, Radu Serban
// =============================================================================

#include "chrono/solver/ChVariablesNode.h"

namespace chrono {

// Register into the object factory, to enable run-time dynamic creation and persistence
CH_FACTORY_REGISTER(ChVariablesNode)

ChVariablesNode::ChVariablesNode() : ChVariables(3), user_data(nullptr), mass(1) {}

ChVariablesNode& ChVariablesNode::operator=(const ChVariablesNode& other) {
    if (&other == this)
        return *this;

    // copy parent class data
    ChVariables::operator=(other);

    // copy class data
    user_data = other.user_data;
    mass = other.mass;

    return *this;
}

// Computes the product of the inverse mass matrix by a vector, and set in result: result = [invMb]*vect
void ChVariablesNode::Compute_invMb_v(ChVectorRef result, ChVectorConstRef vect) const {
    assert(vect.size() == GetDOF());
    assert(result.size() == GetDOF());

    // optimized unrolled operations
    double inv_mass = 1.0 / mass;
    result(0) = inv_mass * vect(0);
    result(1) = inv_mass * vect(1);
    result(2) = inv_mass * vect(2);
}

// Computes the product of the inverse mass matrix by a vector, and increment result: result += [invMb]*vect
void ChVariablesNode::Compute_inc_invMb_v(ChVectorRef result, ChVectorConstRef vect) const {
    assert(vect.size() == GetDOF());
    assert(result.size() == GetDOF());

    // optimized unrolled operations
    double inv_mass = 1.0 / mass;
    result(0) += inv_mass * vect(0);
    result(1) += inv_mass * vect(1);
    result(2) += inv_mass * vect(2);
}

// Computes the product of the mass matrix by a vector, and set in result: result = [Mb]*vect
void ChVariablesNode::Compute_inc_Mb_v(ChVectorRef result, ChVectorConstRef vect) const {
    assert(result.size() == GetDOF());
    assert(vect.size() == GetDOF());

    // optimized unrolled operations
    result(0) += mass * vect(0);
    result(1) += mass * vect(1);
    result(2) += mass * vect(2);
}

// Computes the product of the corresponding block in the system matrix (ie. the mass matrix) by 'vect', scale by c_a,
// and add to 'result'.
// NOTE: the 'vect' and 'result' vectors must already have the size of the total variables&constraints in the system;
// the procedure will use the ChVariable offsets (that must be already updated) to know the indexes in result and vect.
void ChVariablesNode::MultiplyAndAdd(ChVectorRef result, ChVectorConstRef vect, const double c_a) const {
    // optimized unrolled operations
    double scaledmass = c_a * mass;
    result(offset) += scaledmass * vect(offset);
    result(offset + 1) += scaledmass * vect(offset + 1);
    result(offset + 2) += scaledmass * vect(offset + 2);
}

// Add the diagonal of the mass matrix scaled by c_a, to 'result'.
// NOTE: the 'result' vector must already have the size of system unknowns, ie the size of the total variables &
// constraints in the system; the procedure will use the ChVariable offset (that must be already updated) as index.
void ChVariablesNode::DiagonalAdd(ChVectorRef result, const double c_a) const {
    result(this->offset) += c_a * mass;
    result(this->offset + 1) += c_a * mass;
    result(this->offset + 2) += c_a * mass;
}

void ChVariablesNode::PasteMassInto(ChSparseMatrix& storage,
                                    unsigned int row_offset,
                                    unsigned int col_offset,
                                    const double c_a) const {
    double scaledmass = c_a * mass;
    storage.SetElement(offset + row_offset + 0, offset + col_offset + 0, scaledmass);
    storage.SetElement(offset + row_offset + 1, offset + col_offset + 1, scaledmass);
    storage.SetElement(offset + row_offset + 2, offset + col_offset + 2, scaledmass);
}

void ChVariablesNode::ArchiveOut(ChArchiveOut& archive_out) {
    // version number
    archive_out.VersionWrite<ChVariablesNode>();
    // serialize parent class
    ChVariables::ArchiveOut(archive_out);
    // serialize all member data:
    archive_out << CHNVP(mass);
}

void ChVariablesNode::ArchiveIn(ChArchiveIn& archive_in) {
    // version number
    /*int version =*/archive_in.VersionRead<ChVariablesNode>();
    // deserialize parent class
    ChVariables::ArchiveIn(archive_in);
    // stream in all member data:
    archive_in >> CHNVP(mass);
    SetNodeMass(mass);
}

}  // end namespace chrono
