#include "poseParameterization.h"

bool PoseParameterization::Plus(const double *x, const double *delta, double *x_plus_delta) const
{
    Eigen::Map<const Eigen::Vector3d> p_x(x);
    Eigen::Map<const Eigen::Quaterniond> q_x(x + 3);

    Eigen::Map<const Eigen::Vector3d> dp(delta);
    Eigen::Quaterniond dq = zjloc::numType::deltaQ(Eigen::Map<const Eigen::Vector3d>(delta + 3));

    Eigen::Map<Eigen::Vector3d> p_out(x_plus_delta);
    Eigen::Map<Eigen::Quaterniond> q_out(x_plus_delta + 3);

    p_out = p_x + dp;
    q_out = (q_x * dq).normalized();

    return true;
}

bool PoseParameterization::PlusJacobian(const double *, double *jacobian) const
{
    Eigen::Map<Eigen::Matrix<double, 7, 6, Eigen::RowMajor>> j(jacobian);
    j.topRows<6>().setIdentity();
    j.bottomRows<1>().setZero();
    return true;
}

bool PoseParameterization::Minus(const double *y, const double *x, double *y_minus_x) const
{
    Eigen::Map<const Eigen::Vector3d> p_x(x);
    Eigen::Map<const Eigen::Quaterniond> q_x(x + 3);

    Eigen::Map<const Eigen::Vector3d> p_y(y);
    Eigen::Map<const Eigen::Quaterniond> q_y(y + 3);

    Eigen::Map<Eigen::Vector3d> dp(y_minus_x);
    dp = p_y - p_x;

    Eigen::Quaterniond dq = (q_x.conjugate() * q_y).normalized();
    Eigen::Map<Eigen::Vector3d> dtheta(y_minus_x + 3);
    dtheta = 2.0 * dq.vec();

    return true;
}

bool PoseParameterization::MinusJacobian(const double *, double *jacobian) const
{
    Eigen::Map<Eigen::Matrix<double, 6, 7, Eigen::RowMajor>> j(jacobian);
    j.setZero();
    j.block<6, 6>(0, 0).setIdentity();
    return true;
}

bool RotationParameterization::Plus(const double *x, const double *delta, double *x_plus_delta) const
{
    Eigen::Map<const Eigen::Quaterniond> q_x(x);
    Eigen::Quaterniond dq = zjloc::numType::deltaQ(Eigen::Map<const Eigen::Vector3d>(delta));
    Eigen::Map<Eigen::Quaterniond> q_out(x_plus_delta);
    q_out = (q_x * dq).normalized();
    return true;
}

bool RotationParameterization::PlusJacobian(const double *, double *jacobian) const
{
    Eigen::Map<Eigen::Matrix<double, 4, 3, Eigen::RowMajor>> j(jacobian);
    j.topRows<3>().setIdentity();
    j.bottomRows<1>().setZero();
    return true;
}

bool RotationParameterization::Minus(const double *y, const double *x, double *y_minus_x) const
{
    Eigen::Map<const Eigen::Quaterniond> q_x(x);
    Eigen::Map<const Eigen::Quaterniond> q_y(y);

    Eigen::Quaterniond dq = (q_x.conjugate() * q_y).normalized();
    Eigen::Map<Eigen::Vector3d> dtheta(y_minus_x);
    dtheta = 2.0 * dq.vec();

    return true;
}

bool RotationParameterization::MinusJacobian(const double *, double *jacobian) const
{
    Eigen::Map<Eigen::Matrix<double, 3, 4, Eigen::RowMajor>> j(jacobian);
    j.setZero();
    j.block<3, 3>(0, 0).setIdentity();
    return true;
}
