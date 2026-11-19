# frozen_string_literal: true
require "spec_helper"

# CWE-89: SQL Injection — Behavioral Test
#
# The vulnerable code in UsersController#update constructs a SQL query using
# string interpolation directly from user input:
#
#   user = User.where("id = '#{params[:user][:id]}'"[0]
#
# This allows an attacker to inject SQL to target a different user than intended.
# A secure implementation must use parameterized queries so that SQL metacharacters
# in the input are treated as data, never as SQL syntax.
#
# This test asserts the SECURE property: an attacker submitting a crafted SQL
# injection payload in the user[id] field should NOT be able to modify another
# user's data. The test FAILS on vulnerable code because the injection succeeds.

RSpec.describe UsersController, type: :controller do
  describe "#update (CWE-89: SQL Injection via string interpolation)" do
    let(:password) { "thi$ 1s cOmplExEr" }

    let!(:victim_user) do
      User.create!(
        first_name: "Victim",
        last_name:  "Admin",
        email:      "victim_admin@example.com",
        admin:      true,
        password:   password,
        password_confirmation: password
      )
    end

    let!(:attacker_user) do
      User.create!(
        first_name: "Attacker",
        last_name:  "Normal",
        email:      "attacker_normal@example.com",
        admin:      false,
        password:   password,
        password_confirmation: password
      )
    end

    before do
      # Authenticate as the attacker via session
      session[:user_id] = attacker_user.id
    end

    it "should not allow SQL injection in user[id] to modify another user's data" do
      original_email = victim_user.email

      # Craft a SQL injection payload that targets the victim user specifically.
      # Injected into the query template  WHERE id = '#{value}'  the payload becomes:
      #   WHERE id = '' OR (id = <victim_id>) AND '1'='1'
      # This is valid SQL: the AND binds tighter than OR so it evaluates as:
      #   (id = '') OR (id = <victim_id> AND '1'='1')
      # = only the victim row, allowing the attacker to update the victim's data.
      injection_payload = "' OR (id = #{victim_user.id}) AND '1'='1"

      patch :update, params: {
        id: attacker_user.id,
        user: {
          id:           injection_payload,
          email:        "injected_hacker@evil.com",
          first_name:   "Injected",
          last_name:    "Hacker"
        }
      }

      # SECURE BEHAVIOR: The victim's email must remain unchanged.
      # This assertion FAILS on vulnerable code because the SQL injection
      # successfully targets and updates the victim user's record.
      expect(victim_user.reload.email).to eq(original_email),
        "SQL injection via user[id] modified victim user's email. " \
        "The UsersController#update uses string interpolation in " \
        "User.where(\"id = '\#{params[:user][:id]}'\") which allows an authenticated " \
        "attacker to redirect the lookup to any user and overwrite their data. " \
        "The fix is to use parameterized queries: User.where(id: params[:user][:id])."
    end

    it "should not allow SQL injection in user[id] to match all users (OR 1=1 style)" do
      # Set up: attacker has a different first_name from the victim
      original_victim_first_name = victim_user.first_name  # "Victim"

      # OR 1=1 style injection returns ALL users; [0] is the first row.
      # This test verifies that regardless of which user is returned by an OR 1=1
      # payload, the victim's data remains intact.
      injection_payload = "' OR '1'='1"

      patch :update, params: {
        id: attacker_user.id,
        user: {
          id:         injection_payload,
          email:      "mass_hacked@evil.com",
          first_name: "MassHacked",
          last_name:  "Everyone"
        }
      }

      # SECURE BEHAVIOR: Victim's data must not change regardless of the SQL payload.
      # On vulnerable code, the OR '1'='1 injection returns all users and updates
      # the first record — that user's data is now corrupted by the attacker.
      victim_user.reload
      attacker_user.reload

      # Neither user's email should have been set to the injected value
      expect(victim_user.email).not_to eq("mass_hacked@evil.com"),
        "SQL OR 1=1 injection via user[id] changed victim user's email. " \
        "String interpolation in the WHERE clause enabled mass data corruption."

      expect(attacker_user.email).not_to eq("mass_hacked@evil.com"),
        "SQL OR 1=1 injection via user[id] changed attacker user's email. " \
        "String interpolation in the WHERE clause enabled data corruption via " \
        "OR condition that matched all rows."
    end
  end
end
